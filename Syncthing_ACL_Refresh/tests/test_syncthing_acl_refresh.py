from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import pwd
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
from pathlib import Path


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


class RuntimeSettingsTests(unittest.TestCase):
    def test_environment_settings_are_parsed_without_local_identities(self) -> None:
        settings = module.parse_runtime_settings(
            ["--scan"],
            {
                "ACL_USERS": "alice,bob",
                "SYNCTHING_USER": "sync-service",
                "STATE_PATH": "/tmp/acl-state.sqlite3",
                "TLS_CERTIFICATE": "/tmp/syncthing-cert.pem",
            },
        )
        self.assertEqual(("alice", "bob"), settings.acl_users)
        self.assertEqual("sync-service", settings.syncthing_user)
        self.assertEqual(Path("/tmp/acl-state.sqlite3"), settings.state_path)
        self.assertTrue(settings.scan)

    def test_cli_values_override_environment_values(self) -> None:
        settings = module.parse_runtime_settings(
            ["--users", "carol,dave", "--refresh-hours", "6"],
            {"ACL_USERS": "alice,bob", "REFRESH_HOURS": "3"},
        )
        self.assertEqual(("carol", "dave"), settings.acl_users)
        self.assertEqual(6, settings.refresh_hours)

    def test_cli_interval_overrides_an_invalid_environment_value(self) -> None:
        settings = module.parse_runtime_settings(
            ["--users", "carol", "--refresh-hours", "6"],
            {"REFRESH_HOURS": "not-an-integer"},
        )
        self.assertEqual(6, settings.refresh_hours)

    def test_empty_managed_user_list_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "managed ACL user"):
            module.parse_runtime_settings([], {})

    def test_relative_runtime_path_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "absolute"):
            module.parse_runtime_settings([], {"ACL_USERS": "alice", "STATE_PATH": "state.sqlite3"})


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
        self.assertFalse(matcher.directory_requires_access("plugins"))

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
        self.assertTrue(matcher.directory_requires_access("ignored"))

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
                paths,
                {
                    ".stignore",
                    "rules",
                    "rules/first.ignore",
                    "rules/nested",
                    "rules/nested/second.ignore",
                    ".stfolder",
                },
            )

    def test_include_without_negation_does_not_enable_global_traversal(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["private", "private/**"],
        )

        self.assertFalse(matcher.directory_requires_access("private"))

    def test_ignore_before_unrooted_negation_can_still_skip_directory(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["foo", "!**/baz", "*"],
        )

        self.assertFalse(matcher.directory_requires_access("foo"))
        self.assertTrue(matcher.directory_requires_access("other"))

    def test_top_level_rooted_negation_scopes_traversal_to_its_directory(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["!foo", "*"],
        )

        self.assertTrue(matcher.directory_requires_access("foo"))
        self.assertFalse(matcher.directory_requires_access("private"))

    def test_nested_rooted_negation_requires_global_traversal(self) -> None:
        matcher = module.IgnoreMatcher(
            expanded_patterns=["!foo/bar", "*"],
        )

        self.assertTrue(matcher.directory_requires_access("foo"))
        self.assertTrue(matcher.directory_requires_access("private"))

    def test_symlinked_ignore_file_inside_root_is_a_control_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rules = root / "rules"
            rules.mkdir()
            target = rules / "real.ignore"
            target.write_text("*.tmp\n", encoding="utf-8")
            (root / ".stignore").symlink_to(target)

            paths = module.discover_control_paths(root)

            self.assertEqual(
                paths,
                {".stignore", "rules", "rules/real.ignore", ".stfolder"},
            )

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

    def test_hostname_alias_is_rejected_even_when_named_localhost(self) -> None:
        with self.assertRaises(ValueError):
            module.normalize_gui_https("localhost:8384", use_tls=True)

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

    def test_nested_rooted_negation_keeps_unrelated_ignored_directory_traversable(self) -> None:
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
                self.assertIn(self.acl_entry(user, "rwx"), entries)

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

    def test_replaced_former_root_is_reported_once_and_removed_from_active_state(self) -> None:
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
            self.assertEqual(list(state.iter_items()), [])


class EventReliabilityTests(unittest.TestCase):
    def test_queue_overflow_requires_full_reconciliation(self) -> None:
        self.assertTrue(module.events_require_full_reconciliation({"Q_OVERFLOW"}))

    def test_retry_backoff_retries_without_new_event_and_resets_after_success(self) -> None:
        retry = module.RetryBackoff(initial_seconds=5, maximum_seconds=20)
        retry.failed(now=100)
        self.assertFalse(retry.is_due(now=104.9))
        self.assertTrue(retry.is_due(now=105))
        retry.failed(now=105)
        self.assertTrue(retry.is_due(now=115))
        retry.succeeded()
        self.assertIsNone(retry.due_at)
        retry.failed(now=200)
        self.assertTrue(retry.is_due(now=205))

    def test_failed_reconciliation_is_scheduled_for_retry(self) -> None:
        retry = module.RetryBackoff(initial_seconds=5, maximum_seconds=20)

        still_dirty = module.record_reconciliation_result(
            module.ReconcileStats(failed=1), retry, now=100
        )

        self.assertTrue(still_dirty)
        self.assertTrue(retry.is_due(now=105))
        self.assertFalse(retry.is_due(now=104.9))

        clean = module.record_reconciliation_result(
            module.ReconcileStats(), retry, now=105
        )
        self.assertFalse(clean)
        self.assertIsNone(retry.due_at)


if __name__ == "__main__":
    unittest.main()
