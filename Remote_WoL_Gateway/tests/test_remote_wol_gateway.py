import importlib.machinery
import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("remote_wol_gateway", str(ROOT / "remote-wol-gateway"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[LOADER.name] = MODULE
LOADER.exec_module(MODULE)


def valid_environment():
    return {
        "WOL_TOKEN": "test-token",
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
                "wake@router.example", "--", "/usr/sbin/ether-wake", "-i", "br-lan", "02:00:00:00:00:01",
            ],
            MODULE.build_ssh_command(settings),
        )


class GatewayServiceTests(unittest.TestCase):
    def make_service(self, statuses, send_result=True):
        settings = MODULE.Settings.from_env(valid_environment())
        status_iterator = iter(statuses)
        return MODULE.GatewayService(
            settings,
            status_collector=lambda: next(status_iterator),
            wake_sender=lambda: send_result,
            sleep=lambda _seconds: None,
            monotonic=iter((0.0, 0.0, 1.0, 2.0, 61.0)).__next__,
        )

    def test_wrong_bearer_token_is_rejected(self):
        service = self.make_service([])
        status, payload = service.handle("GET", "/status", "Bearer wrong")
        self.assertEqual(401, status)
        self.assertEqual("unauthorized", payload["error"])

    def test_already_online_target_is_not_woken(self):
        sent = []
        settings = MODULE.Settings.from_env(valid_environment())
        service = MODULE.GatewayService(settings, lambda: {"online": True, "checks": {}}, lambda: sent.append(True) or True)
        status, payload = service.handle("POST", "/wol", "Bearer test-token")
        self.assertEqual(200, status)
        self.assertEqual("already_online", payload["result"])
        self.assertEqual([], sent)

    def test_wake_waits_until_target_is_online(self):
        service = self.make_service([
            {"online": False, "checks": {"ping": False}},
            {"online": False, "checks": {"ping": False}},
            {"online": True, "checks": {"ping": True}},
        ])
        status, payload = service.handle("POST", "/wol", "Bearer test-token")
        self.assertEqual(200, status)
        self.assertEqual("wol_sent_online", payload["result"])

    def test_sender_failure_is_reported_as_bad_gateway(self):
        service = self.make_service([{"online": False, "checks": {}}], send_result=False)
        status, payload = service.handle("POST", "/wol", "Bearer test-token")
        self.assertEqual(502, status)
        self.assertEqual("wol_failed", payload["error"])


if __name__ == "__main__":
    unittest.main()
