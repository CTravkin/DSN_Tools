# Remote WoL Gateway

[English](README.md) | [Русский](README.ru.md)

[Back to DSN Tools](../README.md)

`remote-wol-gateway` checks and wakes one configured machine through a bearer-authenticated HTTP API. Use a separate service instance for each target.

Wake-on-LAN can be sent directly over UDP or through an SSH hop. Reachability is checked through ICMP and/or configured TCP ports. SSH is invoked without a local shell and with strict host-key checking.

## Stack

Python standard library, HTTP, UDP Wake-on-LAN, SSH, and systemd.

## Requirements

- Linux with Python 3.10 or newer and systemd
- Local mode: access to the configured UDP broadcast address
- ICMP checks: `/usr/bin/ping`
- SSH mode: `/usr/bin/ssh`, a dedicated key, pinned `known_hosts`, and access to the remote wake executable

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `WOL_TOKEN` | yes | — | Bearer token |
| `WOL_TARGET_IP` | yes | — | Target probe address |
| `WOL_TARGET_MAC` | yes | — | Target MAC address |
| `WOL_TARGET_NAME` | no | `target` | Name returned by the API |
| `WOL_BIND` | no | `127.0.0.1` | Listener address |
| `WOL_PORT` | no | `18080` | Listener port |
| `WOL_WAIT_SECONDS` | no | `60` | Post-wake wait limit |
| `WOL_PROBE_INTERVAL_SECONDS` | no | `2` | Probe interval |
| `WOL_CHECK_PING` | no | `true` | Enable ICMP checks |
| `WOL_CHECK_PORTS` | no | empty | Comma-separated TCP ports |
| `WOL_SEND_MODE` | no | `local` | `local` or `ssh` |
| `WOL_BROADCAST_IP` | no | `255.255.255.255` | UDP destination |
| `WOL_BROADCAST_PORT` | no | `9` | UDP port |
| `WOL_SSH_HOST` | SSH only | — | SSH host |
| `WOL_SSH_USER` | SSH only | — | SSH account |
| `WOL_SSH_KEY` | SSH only | — | Absolute private-key path |
| `WOL_SSH_KNOWN_HOSTS` | SSH only | — | Absolute `known_hosts` path |
| `WOL_SSH_INTERFACE` | SSH only | — | Remote network interface |
| `WOL_SSH_EXECUTABLE` | no | `/usr/sbin/ether-wake` | Remote wake executable |

At least one reachability check must be enabled. See [`remote-wol-gateway.env.example`](remote-wol-gateway.env.example).

## Data exchange

Every request requires `Authorization: Bearer <token>`.

| Request | Result |
|---|---|
| `GET /status` | Probe results and SSH-sender health when applicable |
| `POST /wol` | Already online, confirmed online, still waiting, or sender failure |

Responses are JSON. `POST /wol` returns `202` when a packet was sent but the target did not become reachable before the deadline, and `502` when sending failed.

The service uses plain HTTP. Keep it bound to loopback or place it behind a trusted TLS endpoint or protected tunnel.

## Operations

### Installation

```sh
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin remote-wol-gateway
sudo install -m 0755 remote-wol-gateway /usr/local/sbin/remote-wol-gateway
sudo install -d -o remote-wol-gateway -g remote-wol-gateway -m 0700 /etc/remote-wol-gateway
sudo install -m 0600 remote-wol-gateway.env.example /etc/remote-wol-gateway/remote-wol-gateway.env
sudo install -m 0644 remote-wol-gateway.service /etc/systemd/system/remote-wol-gateway.service
```

Edit the installed environment file. Omit `useradd` if an equivalent account exists.

### Run

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now remote-wol-gateway.service

curl -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/status
curl -X POST -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/wol
```

### Verification

```sh
python3 -m unittest discover -s tests -v
sudo systemctl status remote-wol-gateway.service
sudo journalctl -u remote-wol-gateway.service
```

## Limitations

- Wake-on-LAN depends on the target firmware, power state, and network configuration
- Successful packet delivery does not prove that the target started
- ICMP-only checks can report an online machine as offline when ping is blocked
