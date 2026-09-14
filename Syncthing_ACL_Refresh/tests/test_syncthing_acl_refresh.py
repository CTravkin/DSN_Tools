from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock
from pathlib import Path


try:
    import pwd
except ModuleNotFoundError:
    pwd = types.ModuleType("pwd")
    pwd.getpwnam = lambda _name: (_ for _ in ()).throw(KeyError())
    pwd.getpwuid = lambda _uid: (_ for _ in ()).throw(KeyError())
    sys.modules["pwd"] = pwd


SCRIPT_PATH = Path(
    os.environ.get(
        "SCRIPT_UNDER_TEST",
        Path(__file__).resolve().parents[1] / "syncthing-acl-refresh",
    )
)
loader = importlib.machinery.SourceFileLoader("syncthing_acl_refresh", os.fspath(SCRIPT_PATH))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
loader.exec_module(module)


def get_acl(path: Path) -> set[str]:
    result = subprocess.run(
        ("getfacl", "-cp", "--", os.fspath(path)),
        check=True,
        capture_output=True,
        text=True,
    )
    return {
        line.split("#", 1)[0].strip()
        for line in result.stdout.splitlines()
        if line.split("#", 1)[0].strip()
    }


def available_acl_test_users() -> tuple[str, ...]:
    if os.name != "posix":
        return ()
    configured = os.environ.get("ACL_TEST_USERS", "")
    candidates = [item.strip() for item in configured.split(",") if item.strip()]
    if not candidates:
        candidates = [pwd.getpwuid(os.geteuid()).pw_name, "nobody", "daemon"]
    users: list[str] = []
    for candidate in candidates:
        try:
            pwd.getpwnam(candidate)
        except KeyError:
            continue
        if candidate not in users:
            users.append(candidate)
    return tuple(users[:2])


ACL_TEST_USERS = available_acl_test_users()
ACL_TESTS_AVAILABLE = (
    os.name == "posix"
    and hasattr(os, "geteuid")
    and os.geteuid() == 0
    and len(ACL_TEST_USERS) == 2
    and all(shutil.which(command) for command in ("getfacl", "setfacl", "runuser"))
)


def runtime_environment(**overrides: str) -> dict[str, str]:
    temporary = Path(tempfile.gettempdir())
    environment = {
        "ACL_USERS": "alice",
        "STATE_PATH": os.fspath(temporary / "acl-state.sqlite3"),
        "TLS_CERTIFICATE": os.fspath(temporary / "syncthing-cert.pem"),
        "FOLDER_ALLOWLIST": os.fspath(temporary / "folders.conf"),
    }
    environment.update(overrides)
    return environment


class RuntimeSettingsTests(unittest.TestCase):
    def test_environment_settings_are_parsed_without_local_identities(self) -> None:
        temporary = Path(tempfile.gettempdir())
        settings = module.parse_runtime_settings(
            [],
            {
                "ACL_USERS": "alice,bob",
                "SYNCTHING_USER": "sync-service",
                "STATE_PATH": os.fspath(temporary / "acl-state.sqlite3"),
                "TLS_CERTIFICATE": os.fspath(temporary / "syncthing-cert.pem"),
                "FOLDER_ALLOWLIST": os.fspath(temporary / "folders.conf"),
            },
        )
        self.assertEqual(("alice", "bob"), settings.acl_users)
        self.assertEqual("sync-service", settings.syncthing_user)
        self.assertEqual(temporary / "acl-state.sqlite3", settings.state_path)
        self.assertEqual(temporary / "folders.conf", settings.allowlist_path)

    def test_cli_values_override_environment_values(self) -> None:
        settings = module.parse_runtime_settings(
            ["--users", "carol,dave"],
            runtime_environment(ACL_USERS="alice,bob"),
        )
        self.assertEqual(("carol", "dave"), settings.acl_users)

    def test_empty_managed_user_list_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "managed ACL user"):
            module.parse_runtime_settings([], {})

    def test_relative_runtime_path_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "absolute"):
            module.parse_runtime_settings([], {"ACL_USERS": "alice", "STATE_PATH": "state.sqlite3"})

    def test_env_file_supplies_one_shot_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            env_file = Path(temporary) / "settings.env"
            env_file.write_text(
                f"ACL_USERS=alice\nSTATE_PATH={temporary}/state.sqlite3\n"
                f"TLS_CERTIFICATE={temporary}/cert.pem\n"
                f"FOLDER_ALLOWLIST={temporary}/folders.conf\n",
                encoding="utf-8",
            )

            settings = module.parse_runtime_settings(
                ["--env-file", os.fspath(env_file)],
                {},
            )

        self.assertEqual(("alice",), settings.acl_users)
        self.assertEqual(Path(temporary) / "folders.conf", settings.allowlist_path)


class FolderAllowlistTests(unittest.TestCase):
    def test_allowlist_selects_a_subset_of_configured_folders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            managed = module.FolderConfiguration("managed", base / "managed")
            unrelated = module.FolderConfiguration("unrelated", base / "unrelated")
            allowlist = module.parse_folder_allowlist(f"managed={managed.path}\n")

            self.assertEqual(
                [managed], module.require_allowed_folders([managed, unrelated], allowlist)
            )

    @unittest.skipUnless(os.name == "posix", "root-path check uses POSIX semantics")
    def test_only_the_filesystem_root_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "filesystem root"):
            module.parse_folder_allowlist("folder=/\n")
        self.assertEqual(
            {"folder": Path("/var/lib/syncthing/data")},
            module.parse_folder_allowlist("folder=/var/lib/syncthing/data\n"),
        )


class IgnoreMatcherTests(unittest.TestCase):
    def test_empty_ignore_response_is_treated_as_no_patterns(self) -> None:
        gui = module.GuiConfiguration(
            url="https://127.0.0.1:8384",
            api_key="not-used",
            certificate_path=Path("/tmp/https-cert.pem"),
        )
        with mock.patch.object(module, "api_json", return_value={"ignore": None, "expanded": None}):
            matcher = module.read_ignore_matcher(gui, "empty-folder", Path("/tmp"))

        self.assertTrue(matcher.is_included("anything/file.txt"))

    def test_top_level_whitelist_excludes_everything_else(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=[
                "!AGENTS.md",
                "!agents",
                "!agents/**",
                "*",
                "**/*",
                "*/**",
                "**/*/**",
            ],
        )

        self.assertTrue(matcher.is_included("AGENTS.md"))
        self.assertTrue(matcher.is_included("agents/worker.md"))
        self.assertFalse(matcher.is_included("plugins/cache/data.json"))
        self.assertEqual(module.AccessLevel.NONE, matcher.directory_access("plugins"))

    def test_blacklist_and_case_insensitive_patterns_are_honored(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["(?i)Backups", "(?i)Backups/**"],
        )

        self.assertFalse(matcher.is_included("backups/archive.tar"))
        self.assertTrue(matcher.is_included("Documents/archive.tar"))

    def test_non_top_level_include_keeps_traversal_access(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["!**/frobble", "*", "**/*", "*/**", "**/*/**"],
        )

        self.assertFalse(matcher.is_included("ignored/file.txt"))
        self.assertEqual(module.AccessLevel.TRAVERSE, matcher.directory_access("ignored"))

    def test_first_match_and_glob_features_match_expanded_syncthing_patterns(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=[
                "!keep/{one,two}.txt",
                "keep/**",
                "(?i)[a-c]ache/**",
                r"literal/\[file\].txt",
            ],
        )

        self.assertTrue(matcher.is_included("keep/one.txt"))
        self.assertFalse(matcher.is_included("keep/three.txt"))
        self.assertFalse(matcher.is_included("Cache/item"))
        self.assertFalse(matcher.is_included("literal/[file].txt"))

    def test_nested_include_files_and_parent_directories_are_control_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rules = root / "rules"
            nested = rules / "nested"
            nested.mkdir(parents=True)
            (root / ".stignore").write_text("#include rules/first.ignore\n", encoding="utf-8")
            (rules / "first.ignore").write_text(
                "#include nested/second.ignore\n", encoding="utf-8"
            )
            (nested / "second.ignore").write_text("*.tmp\n", encoding="utf-8")

            paths = module.discover_control_paths(root)

            self.assertEqual(
                paths.files,
                {
                    ".stignore",
                    "rules/first.ignore",
                    "rules/nested/second.ignore",
                    ".stfolder",
                },
            )
            self.assertEqual(paths.parents, {"rules", "rules/nested"})

    def test_include_without_negation_does_not_enable_global_traversal(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["private", "private/**"],
        )

        self.assertEqual(module.AccessLevel.NONE, matcher.directory_access("private"))

    def test_ignore_before_unrooted_negation_can_still_skip_directory(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["foo", "!**/baz", "*"],
        )

        self.assertEqual(module.AccessLevel.NONE, matcher.directory_access("foo"))
        self.assertEqual(module.AccessLevel.TRAVERSE, matcher.directory_access("other"))

    def test_top_level_rooted_negation_scopes_traversal_to_its_directory(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["!foo", "*"],
        )

        self.assertEqual(module.AccessLevel.FULL, matcher.directory_access("foo"))
        self.assertEqual(module.AccessLevel.NONE, matcher.directory_access("private"))

    def test_control_parent_traversal_is_a_floor_not_a_downgrade(self) -> None:
        matcher = module.IgnoreMatcher([], control_parents={"rules"})

        self.assertEqual(module.AccessLevel.FULL, matcher.directory_access("rules"))

    def test_control_file_denial_wins_across_nested_policies(self) -> None:
        root = Path("/srv/sync")
        path = root / ".stignore"
        policies = [
            module.FolderPolicy("outer", root, module.IgnoreMatcher([])),
            module.FolderPolicy("nested", root / ".stignore", module.IgnoreMatcher([])),
        ]

        self.assertEqual(
            module.AccessLevel.NONE,
            module.desired_for_policies(path, False, policies),
        )

    def test_nested_rooted_negation_requires_global_traversal(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["!foo/bar", "*"],
        )

        self.assertEqual(module.AccessLevel.TRAVERSE, matcher.directory_access("foo"))
        self.assertEqual(module.AccessLevel.TRAVERSE, matcher.directory_access("private"))

    def test_symlinked_ignore_file_inside_root_is_a_control_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rules = root / "rules"
            rules.mkdir()
            target = rules / "real.ignore"
            target.write_text("*.tmp\n", encoding="utf-8")
            (root / ".stignore").symlink_to(target)

            paths = module.discover_control_paths(root)

            self.assertEqual(paths.files, {".stignore", "rules/real.ignore", ".stfolder"})
            self.assertEqual(paths.parents, {"rules"})

    def test_symlinked_ignore_file_outside_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            root.mkdir()
            external = base / "external.ignore"
            external.write_text("*.tmp\n", encoding="utf-8")
            (root / ".stignore").symlink_to(external)

            with self.assertRaisesRegex(ValueError, "escapes the folder root"):
                module.discover_control_paths(root)


class ApiTransportTests(unittest.TestCase):
    def test_https_loopback_gui_and_certificate_are_loaded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            config = base / "config.xml"
            config.write_text(
                """
                <configuration>
                  <gui enabled="true" tls="true">
                    <address>127.0.0.1:8384</address>
                    <apikey>secret</apikey>
                  </gui>
                </configuration>
                """,
                encoding="utf-8",
            )

            gui, folders = module.read_configuration(config, base)

            self.assertEqual(gui.url, "https://127.0.0.1:8384")
            self.assertEqual(gui.certificate_path, module.PINNED_CERTIFICATE_PATH)
            self.assertEqual(folders, [])

    def test_plain_http_gui_is_rejected_for_root_helper(self) -> None:
        with self.assertRaises(ValueError):
            module.normalize_gui_https("127.0.0.1:8384", use_tls=False)

    def test_duplicate_syncthing_folder_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            config = base / "config.xml"
            config.write_text(
                """
                <configuration>
                  <gui enabled="true" tls="true">
                    <address>127.0.0.1:8384</address><apikey>secret</apikey>
                  </gui>
                  <folder id="documents" path="first" />
                  <folder id="documents" path="second" />
                </configuration>
                """,
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "Duplicate Syncthing folder ID"):
                module.read_configuration(config, base)

    def test_hostname_alias_is_rejected_even_when_named_localhost(self) -> None:
        with self.assertRaises(ValueError):
            module.normalize_gui_https("localhost:8384", use_tls=True)

    @unittest.skipUnless(shutil.which("openssl"), "requires openssl")
    def test_mismatched_pinned_certificate_rejects_connection_before_api_key_is_sent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            server_certificate = base / "server-cert.pem"
            server_key = base / "server-key.pem"
            wrong_certificate = base / "wrong-cert.pem"
            wrong_key = base / "wrong-key.pem"
            for certificate, key, common_name in (
                (server_certificate, server_key, "server"),
                (wrong_certificate, wrong_key, "wrong"),
            ):
                subprocess.run(
                    (
                        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", "1", "-subj", f"/CN={common_name}",
                        "-keyout", os.fspath(key), "-out", os.fspath(certificate),
                    ),
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            received: list[bytes] = []
            server_errors: list[BaseException] = []

            def serve_once() -> None:
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(server_certificate, server_key)
                try:
                    connection, _address = listener.accept()
                    with connection, context.wrap_socket(connection, server_side=True) as tls:
                        tls.settimeout(2)
                        received.append(tls.recv(65536))
                except BaseException as error:
                    server_errors.append(error)
                finally:
                    listener.close()

            server = threading.Thread(target=serve_once, daemon=True)
            server.start()
            gui = module.GuiConfiguration(
                url=f"https://127.0.0.1:{port}",
                api_key="SENSITIVE_API_KEY_SENTINEL",
                certificate_path=wrong_certificate,
            )

            with self.assertRaises(ssl.SSLError):
                module.api_json(gui, "/rest/system/status", {})
            server.join(timeout=5)

            self.assertFalse(server.is_alive())
            self.assertNotIn(b"SENSITIVE_API_KEY_SENTINEL", b"".join(received))
            self.assertFalse(
                [error for error in server_errors if not isinstance(error, ssl.SSLEOFError)]
            )


@unittest.skipUnless(
    ACL_TESTS_AVAILABLE,
    "requires root, two local users, getfacl, setfacl, and runuser",
)
class AclReconciliationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.previous_acl_users = module.ACL_USERS
        module.ACL_USERS = ACL_TEST_USERS

    @classmethod
    def tearDownClass(cls) -> None:
        module.ACL_USERS = cls.previous_acl_users

    def acl_entry(self, user: str, permissions: str) -> str:
        return f"user:{user}:{permissions}"

    def test_nested_rooted_negation_grants_only_traversal_to_ignored_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            private = root / "private"
            private.mkdir(parents=True, mode=0o700)
            state = module.StateStore(base / "state.sqlite3")
            matcher = module.IgnoreMatcher(expanded_patterns=["!foo/bar", "*"])

            with mock.patch.object(module, "log"):
                stats = module.reconcile_root(root, matcher, state, force=True)

            self.assertEqual(stats.failed, 0)
            entries = get_acl(private)
            for user in ACL_TEST_USERS:
                self.assertIn(self.acl_entry(user, "--x"), entries)

    def test_control_file_does_not_receive_managed_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            root.mkdir()
            control = root / ".stignore"
            control.write_text("*.tmp\n", encoding="utf-8")
            for user in ACL_TEST_USERS:
                subprocess.run(("setfacl", "-m", f"u:{user}:rw", "--", os.fspath(control)), check=True)
            matcher = module.IgnoreMatcher([], control_files={".stignore", ".stfolder"})
            state = module.StateStore(base / "state.sqlite3")

            stats = module.reconcile_root(root, matcher, state, force=True)

            self.assertEqual(0, stats.failed)
            entries = get_acl(control)
            for user in ACL_TEST_USERS:
                self.assertFalse(any(item.startswith(f"user:{user}:") for item in entries))

    def test_changed_managed_users_reconciles_cached_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            path = base / "document.txt"
            path.write_text("data", encoding="utf-8")
            state = module.StateStore(base / "state.sqlite3")
            original_users = module.ACL_USERS
            try:
                module.ACL_USERS = (ACL_TEST_USERS[0],)
                first = module.reconcile_path(path, module.AccessLevel.FULL, state, allowed_roots=[base])
                module.ACL_USERS = (ACL_TEST_USERS[1],)
                second = module.reconcile_path(path, module.AccessLevel.FULL, state, allowed_roots=[base])
            finally:
                module.ACL_USERS = original_users
                state.close()

            self.assertEqual(1, second.acl_reads)
            entries = get_acl(path)
            self.assertFalse(any(item.startswith(f"user:{ACL_TEST_USERS[0]}:") for item in entries))
            self.assertIn(self.acl_entry(ACL_TEST_USERS[1], "rw-"), entries)

    def test_excluded_directory_loses_named_acl_but_owner_keeps_access(self) -> None:
        for owner_name in ACL_TEST_USERS:
            with self.subTest(owner=owner_name), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                base.chmod(0o711)
                path = base / "excluded"
                path.mkdir(mode=0o700)
                owner = pwd.getpwnam(owner_name)
                os.chown(path, owner.pw_uid, owner.pw_gid)
                subprocess.run(
                    (
                        "setfacl",
                        "-m",
                        ",".join(
                            [f"u:{user}:rwx" for user in ACL_TEST_USERS]
                            + [f"d:u:{user}:rwx" for user in ACL_TEST_USERS]
                        ),
                        "--",
                        os.fspath(path),
                    ),
                    check=True,
                )

                module.set_managed_access(path, should_have_access=False)

                entries = get_acl(path)
                for user in ACL_TEST_USERS:
                    self.assertNotIn(self.acl_entry(user, "rwx"), entries)
                    self.assertNotIn(f"default:user:{user}:rwx", entries)
                self.assertEqual(path.stat().st_uid, owner.pw_uid)
                result = subprocess.run(
                    ("runuser", "-u", owner_name, "--", "test", "-w", os.fspath(path)),
                    check=False,
                )
                self.assertEqual(result.returncode, 0)

    def test_excluded_unix_socket_loses_inherited_named_acl(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            path = base / "excluded.sock"
            server = socket.socket(socket.AF_UNIX)
            try:
                server.bind(os.fspath(path))
                subprocess.run(
                    (
                        "setfacl", "-m",
                        ",".join(f"u:{user}:rw" for user in ACL_TEST_USERS),
                        "--", os.fspath(path),
                    ),
                    check=True,
                )

                outcome = module.set_managed_access(path, should_have_access=False)

                self.assertEqual(outcome, module.AclOutcome.CHANGED)
                entries = get_acl(path)
                for user in ACL_TEST_USERS:
                    self.assertFalse(any(item.startswith(f"user:{user}:") for item in entries))
            finally:
                server.close()

    def test_non_executable_file_loses_managed_execute_permission(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "document.txt"
            path.write_text("data", encoding="utf-8")
            subprocess.run(
                (
                    "setfacl", "-m",
                    ",".join([f"u:{user}:rwx" for user in ACL_TEST_USERS] + ["m::rwx"]),
                    "--", os.fspath(path),
                ),
                check=True,
            )

            outcome = module.set_managed_access(path, should_have_access=True)

            self.assertEqual(outcome, module.AclOutcome.CHANGED)
            entries = get_acl(path)
            for user in ACL_TEST_USERS:
                self.assertIn(self.acl_entry(user, "rw-"), entries)

    def test_group_only_executable_grants_execute_to_managed_users(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "group-executable"
            path.write_text("data", encoding="utf-8")
            path.chmod(0o010)

            outcome = module.set_managed_access(path, should_have_access=True)

            self.assertEqual(outcome, module.AclOutcome.CHANGED)
            entries = get_acl(path)
            for user in ACL_TEST_USERS:
                self.assertIn(self.acl_entry(user, "rwx"), entries)

    def test_first_default_acl_scaffold_does_not_grant_group_or_other_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "shared"
            path.mkdir(mode=0o775)
            path.chmod(0o775)

            outcome = module.set_managed_access(path, should_have_access=True)

            self.assertEqual(outcome, module.AclOutcome.CHANGED)
            entries = get_acl(path)
            self.assertIn("default:user::rwx", entries)
            for user in ACL_TEST_USERS:
                self.assertIn(f"default:user:{user}:rwx", entries)
            self.assertIn("default:group::---", entries)
            self.assertIn("default:mask::rwx", entries)
            self.assertIn("default:other::---", entries)

            previous_umask = os.umask(0o077)
            try:
                child = path / "child"
                child.mkdir(mode=0o777)
            finally:
                os.umask(previous_umask)
            child_entries = get_acl(child)
            for user in ACL_TEST_USERS:
                self.assertIn(self.acl_entry(user, "rwx"), child_entries)
            self.assertIn("group::---", child_entries)
            self.assertIn("other::---", child_entries)

    def test_mask_conflict_fails_without_expanding_unmanaged_effective_rights(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "conflict.txt"
            path.write_text("data", encoding="utf-8")
            subprocess.run(
                ("setfacl", "-n", "-m", "u:www-data:rwx,m::r--", "--", os.fspath(path)),
                check=True,
            )

            outcome = module.set_managed_access(path, should_have_access=True)

            self.assertEqual(outcome, module.AclOutcome.FAILED)
            result = subprocess.run(
                ("getfacl", "-cp", "--", os.fspath(path)),
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("user:www-data:rwx", result.stdout)
            self.assertIn("mask::r--", result.stdout)
            for user in ACL_TEST_USERS:
                self.assertNotIn(f"user:{user}:", result.stdout)

    def test_intermediate_symlink_outside_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            outside = base / "outside"
            root.mkdir()
            outside.mkdir()
            target = outside / "target"
            target.write_text("protected", encoding="utf-8")
            (root / "escape").symlink_to(outside, target_is_directory=True)

            with module.ManagedRoot(root) as managed_root:
                with self.assertRaises(module.UnsafePathError):
                    managed_root.open_target(root / "escape" / "target")

    def test_failed_acl_read_is_not_cached_and_next_pass_retries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            root.mkdir()
            path = root / "file.txt"
            path.write_text("data", encoding="utf-8")
            state = module.StateStore(base / "state.sqlite3")

            with mock.patch.object(
                module,
                "acl_entries",
                side_effect=subprocess.CalledProcessError(1, "getfacl"),
            ):
                failed = module.reconcile_path(
                    path, True, state, force=True, allowed_roots=[root]
                )

            self.assertEqual(failed.failed, 1)
            self.assertIsNone(state.get(path))
            retried = module.reconcile_path(
                path, True, state, force=False, allowed_roots=[root]
            )
            self.assertEqual(retried.acl_reads, 1)
            self.assertEqual(retried.failed, 0)

    def test_unchanged_second_reconciliation_performs_no_acl_reads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            root.mkdir()
            for index in range(200):
                (root / f"file-{index}.txt").write_text("data", encoding="utf-8")
            state = module.StateStore(base / "state.sqlite3")
            matcher = module.IgnoreMatcher(expanded_patterns=[])

            with mock.patch.object(module, "log"):
                first = module.reconcile_root(root, matcher, state, force=True)
                second = module.reconcile_root(root, matcher, state, force=False)

            self.assertGreater(first.acl_reads, 0)
            self.assertEqual(second.acl_reads, 0)
            self.assertEqual(second.changed, 0)

    def test_replaced_former_root_is_reported_once_and_removed_from_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "folder"
            root.mkdir()
            for index in range(40):
                (root / f"file-{index}.txt").write_text("data", encoding="utf-8")
            state = module.StateStore(base / "state.sqlite3")
            matcher = module.IgnoreMatcher(expanded_patterns=[])
            with mock.patch.object(module, "log"):
                module.reconcile_root(root, matcher, state, force=True)

            moved = base / "moved-folder"
            root.rename(moved)
            root.mkdir()
            for index in range(40):
                (root / f"file-{index}.txt").write_text("replacement", encoding="utf-8")
            stats = module.ReconcileStats()
            with mock.patch.object(module, "log") as mocked_log:
                module.reconcile_removed_state(state, [], stats, force=False)

            warnings = [
                call for call in mocked_log.call_args_list
                if "Former managed root identity changed" in str(call)
            ]
            self.assertEqual(len(warnings), 1)
            self.assertEqual(len(list(state.iter_items())), 0)


class StateMigrationTests(unittest.TestCase):
    def test_legacy_state_is_migrated_without_losing_revoke_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.sqlite3"
            managed_path = Path(temporary) / "folder" / "file"
            anchor = Path(temporary) / "folder"
            anchor.mkdir()
            managed_path.write_text("data", encoding="utf-8")
            connection = module.sqlite3.connect(path)
            connection.execute(
                "CREATE TABLE paths (path TEXT PRIMARY KEY, ctime_ns INTEGER NOT NULL, "
                "desired INTEGER NOT NULL, anchor TEXT NOT NULL, anchor_dev INTEGER NOT NULL, "
                "anchor_ino INTEGER NOT NULL)"
            )
            connection.execute(
                "INSERT INTO paths VALUES (?, ?, ?, ?, ?, ?)",
                (os.fspath(managed_path), 123, 1, os.fspath(anchor), 10, 20),
            )
            connection.commit()
            connection.close()
            previous_users = module.ACL_USERS
            module.ACL_USERS = ("current-user",)
            try:
                state = module.StateStore(path)
                record = state.get(managed_path)
                state.close()
            finally:
                module.ACL_USERS = previous_users

        self.assertIsNotNone(record)
        assert record is not None
        self.assertEqual(module.AccessLevel.FULL, record.access)
        self.assertEqual(("current-user",), record.users)

    def test_unknown_state_schema_is_rejected_without_dropping_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.sqlite3"
            connection = module.sqlite3.connect(path)
            connection.execute("CREATE TABLE paths (path TEXT PRIMARY KEY, mystery TEXT)")
            connection.execute("INSERT INTO paths VALUES ('sentinel', 'keep')")
            connection.commit()
            connection.close()

            with self.assertRaisesRegex(ValueError, "Unsupported state database schema"):
                module.StateStore(path)

            connection = module.sqlite3.connect(path)
            row = connection.execute("SELECT path, mystery FROM paths").fetchone()
            connection.close()

        self.assertEqual(("sentinel", "keep"), row)


class WalkReliabilityTests(unittest.TestCase):
    def test_walk_error_marks_reconciliation_failed(self) -> None:
        stats = module.ReconcileStats()

        def fail_walk(_root: Path, **options: object):
            options["onerror"](PermissionError("denied"))
            return iter(())

        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(module.os, "walk", side_effect=fail_walk):
                self.assertEqual([], list(module.walk_paths(Path(temporary), stats)))

        self.assertEqual(1, stats.failed)

class MainTests(unittest.TestCase):
    def test_default_invocation_runs_one_scan(self) -> None:
        settings = types.SimpleNamespace(revoke_all=False, force=False)
        with mock.patch.object(module, "parse_runtime_settings", return_value=settings), mock.patch.object(
            module, "apply_runtime_settings"
        ), mock.patch.object(module.pwd, "getpwnam"), mock.patch.object(
            module, "scan_once", return_value=0
        ) as scan:
            exit_code = module.main()

        self.assertEqual(0, exit_code)
        scan.assert_called_once_with(False)


if __name__ == "__main__":
    unittest.main()
