import importlib.machinery
import importlib.util
import http.client
import pathlib
import sys
import threading
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("remote_wol_gateway", str(ROOT / "remote-wol-gateway"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = MODULE
LOADER.exec_module(MODULE)


def valid_environment():
    return {
        "WOL_TOKEN": "0123456789abcdef0123456789abcdef",
        "WOL_TARGET_IP": "192.0.2.10",
        "WOL_TARGET_MAC": "02:00:00:00:00:01",
        "WOL_CHECK_PING": "true",
        "WOL_SEND_MODE": "local",
    }


class SettingsTests(unittest.TestCase):
    def test_missing_required_identity_is_rejected(self):
        environment = valid_environment()
        del environment["WOL_TARGET_MAC"]
        with self.assertRaisesRegex(MODULE.ConfigurationError, "TARGET_MAC"):
            MODULE.Settings.from_env(environment)

    def test_invalid_probe_configuration_is_rejected(self):
        environment = valid_environment()
        environment["WOL_CHECK_PING"] = "false"
        with self.assertRaisesRegex(MODULE.ConfigurationError, "probe"):
            MODULE.Settings.from_env(environment)

    def test_ssh_mode_requires_strict_connection_files(self):
        environment = valid_environment()
        environment["WOL_SEND_MODE"] = "ssh"
        with self.assertRaisesRegex(MODULE.ConfigurationError, "SSH_HOST"):
            MODULE.Settings.from_env(environment)

    def test_placeholder_or_short_token_is_rejected(self):
        for token in ("test-token", "replace-with-a-long-random-token"):
            environment = valid_environment()
            environment["WOL_TOKEN"] = token
            with self.subTest(token=token), self.assertRaisesRegex(
                MODULE.ConfigurationError, "WOL_TOKEN"
            ):
                MODULE.Settings.from_env(environment)

    def test_ipv6_is_rejected_for_ipv4_only_fields(self):
        for field in ("WOL_TARGET_IP", "WOL_BIND", "WOL_BROADCAST_IP"):
            environment = valid_environment()
            environment[field] = "::1"
            with self.subTest(field=field), self.assertRaisesRegex(
                MODULE.ConfigurationError, "IPv4"
            ):
                MODULE.Settings.from_env(environment)


class SenderTests(unittest.TestCase):
    def test_magic_packet_has_six_ff_bytes_and_sixteen_mac_repetitions(self):
        packet = MODULE.build_magic_packet("02:00:00:00:00:01")
        self.assertEqual(102, len(packet))
        self.assertEqual(b"\xff" * 6, packet[:6])
        self.assertEqual(bytes.fromhex("020000000001") * 16, packet[6:])

    def test_ssh_command_is_argument_vector_with_strict_host_checking(self):
        environment = valid_environment()
        environment.update(
            {
                "WOL_SEND_MODE": "ssh",
                "WOL_SSH_HOST": "router.example",
                "WOL_SSH_USER": "wake",
                "WOL_SSH_KEY": "/etc/remote-wol-gateway/wake_ed25519",
                "WOL_SSH_KNOWN_HOSTS": "/etc/remote-wol-gateway/known_hosts",
                "WOL_SSH_INTERFACE": "br-lan",
            }
        )
        settings = MODULE.Settings.from_env(environment)
        self.assertEqual(
            [
                "/usr/bin/ssh", "-i", "/etc/remote-wol-gateway/wake_ed25519",
                "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "UserKnownHostsFile=/etc/remote-wol-gateway/known_hosts",
                "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                "-o", "LogLevel=ERROR",
                "wake@router.example", "/usr/local/sbin/remote-wol-sender", "--wake", "br-lan", "02:00:00:00:00:01",
            ],
            MODULE.build_ssh_command(settings),
        )


class GatewayServiceTests(unittest.TestCase):
    def make_service(self, statuses, send_result=True):
        settings = MODULE.Settings.from_env(valid_environment())
        status_iterator = iter(statuses)
        return MODULE.GatewayService(
            settings,
            status_collector=lambda _timeout=None: next(status_iterator),
            wake_sender=lambda: send_result,
            sleep=lambda _seconds: None,
            monotonic=iter((0.0, 0.0, 1.0, 1.0, 2.0, 2.0, 3.0)).__next__,
        )

    def test_wrong_bearer_token_is_rejected(self):
        service = self.make_service([])
        status, payload = service.handle("GET", "/status", "Bearer wrong")
        self.assertEqual(401, status)
        self.assertEqual("unauthorized", payload["error"])

    def test_already_online_target_is_not_woken(self):
        sent = []
        settings = MODULE.Settings.from_env(valid_environment())
        service = MODULE.GatewayService(settings, lambda _timeout=None: {"online": True, "checks": {}}, lambda: sent.append(True) or True)
        status, payload = service.handle("POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef")
        self.assertEqual(200, status)
        self.assertEqual("already_online", payload["result"])
        self.assertEqual([], sent)

    def test_wake_waits_until_target_is_online(self):
        service = self.make_service([
            {"online": False, "checks": {"ping": False}},
            {"online": False, "checks": {"ping": False}},
            {"online": True, "checks": {"ping": True}},
        ])
        status, payload = service.handle("POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef")
        self.assertEqual(200, status)
        self.assertEqual("wol_sent_online", payload["result"])

    def test_sender_failure_is_reported_as_bad_gateway(self):
        service = self.make_service([{"online": False, "checks": {}}], send_result=False)
        status, payload = service.handle("POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef")
        self.assertEqual(502, status)
        self.assertEqual("wol_failed", payload["error"])

    def test_wait_never_sleeps_beyond_remaining_deadline(self):
        environment = valid_environment()
        environment.update({"WOL_WAIT_SECONDS": "5", "WOL_PROBE_INTERVAL_SECONDS": "4"})
        settings = MODULE.Settings.from_env(environment)
        clock = iter((0.0, 0.0, 3.0, 3.0, 5.0)).__next__
        sleeps = []
        timeouts = []
        service = MODULE.GatewayService(
            settings,
            status_collector=lambda timeout=None: timeouts.append(timeout) or {"online": False, "checks": {}},
            wake_sender=lambda: True,
            sleep=sleeps.append,
            monotonic=clock,
        )

        status, payload = service.handle(
            "POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef"
        )

        self.assertEqual(202, status)
        self.assertEqual([4, 2.0], sleeps)
        self.assertEqual(2.0, timeouts[-1])

    def test_parallel_wake_is_rejected_while_first_is_running(self):
        settings = MODULE.Settings.from_env(valid_environment())
        entered = threading.Event()
        release = threading.Event()

        def status_collector(_timeout=None):
            entered.set()
            release.wait(2)
            return {"online": False, "checks": {}}

        service = MODULE.GatewayService(settings, status_collector, lambda: False)
        first = threading.Thread(
            target=lambda: service.handle(
                "POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef"
            )
        )
        first.start()
        self.assertTrue(entered.wait(1))
        status, payload = service.handle(
            "POST", "/wol", "Bearer 0123456789abcdef0123456789abcdef"
        )
        release.set()
        first.join(2)

        self.assertEqual(409, status)
        self.assertEqual("wake_in_progress", payload["error"])


class HttpServerTests(unittest.TestCase):
    def test_status_endpoint_returns_json_and_does_not_expose_server_runtime(self):
        settings = MODULE.Settings.from_env(valid_environment())
        service = MODULE.GatewayService(
            settings, lambda _timeout=None: {"online": True, "checks": {"ping": True}}
        )
        server = MODULE.GatewayHTTPServer(("127.0.0.1", 0), service)
        worker = threading.Thread(target=server.handle_request)
        worker.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        connection.request(
            "GET", "/status", headers={"Authorization": "Bearer 0123456789abcdef0123456789abcdef"}
        )
        response = connection.getresponse()
        body = response.read()
        connection.close()
        worker.join(2)
        server.server_close()

        self.assertEqual(200, response.status)
        self.assertEqual("application/json; charset=utf-8", response.getheader("Content-Type"))
        self.assertNotIn("Python", response.getheader("Server", ""))
        self.assertTrue(MODULE.json.loads(body)["online"])


class MainTests(unittest.TestCase):
    def test_ssh_sender_outage_does_not_prevent_gateway_start(self):
        environment = valid_environment()
        environment.update(
            {
                "WOL_SEND_MODE": "ssh",
                "WOL_SSH_HOST": "router.example",
                "WOL_SSH_USER": "wake",
                "WOL_SSH_KEY": "/etc/remote-wol-gateway/wake_ed25519",
                "WOL_SSH_KNOWN_HOSTS": "/etc/remote-wol-gateway/known_hosts",
                "WOL_SSH_INTERFACE": "br-lan",
            }
        )
        settings = MODULE.Settings.from_env(environment)
        server = mock.Mock()
        with mock.patch.object(MODULE.Settings, "from_env", return_value=settings), mock.patch.object(
            MODULE, "GatewayHTTPServer", return_value=server
        ), mock.patch.object(MODULE, "run_command", return_value=False):
            exit_code = MODULE.main()

        self.assertEqual(0, exit_code)
        server.serve_forever.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
