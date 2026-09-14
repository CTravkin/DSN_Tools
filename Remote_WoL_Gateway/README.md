# Remote WoL Gateway

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.md)

`remote-wol-gateway` exposes a small bearer-authenticated HTTP API for checking and waking one configured machine. It sends Wake-on-LAN locally over UDP or through a constrained SSH sender and confirms reachability through ICMP and/or TCP probes.

The listener is IPv4-only, processes a bounded queue serially, and allows only one wake operation at a time. Keep it bound to loopback or place it behind a trusted tunnel or TLS endpoint; the service itself serves plain HTTP.

## Requirements

- Linux, Python 3.10+, and systemd
- Local mode: access to the required IPv4 broadcast address
- Ping checks: `/usr/bin/ping`
- SSH mode: `/usr/bin/ssh`, a dedicated key, pinned `known_hosts`, and [`remote-wol-sender`](remote-wol-sender) on the sending host

## Configuration

Copy [`remote-wol-gateway.env.example`](remote-wol-gateway.env.example).

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `WOL_TOKEN` | yes | — | Non-placeholder bearer secret of at least 32 bytes |
| `WOL_TARGET_IP` | yes | — | Target IPv4 probe address |
| `WOL_TARGET_MAC` | yes | — | Target MAC address |
| `WOL_TARGET_NAME` | no | `target` | Name returned by the API |
| `WOL_BIND` / `WOL_PORT` | no | `127.0.0.1` / `18080` | IPv4 listener |
| `WOL_WAIT_SECONDS` | no | `60` | Maximum post-send confirmation period |
| `WOL_PROBE_INTERVAL_SECONDS` | no | `2` | Delay between probes |
| `WOL_CHECK_PING` | no | `true` | Enable ICMP probing |
| `WOL_CHECK_PORTS` | no | empty | Comma-separated TCP ports |
| `WOL_SEND_MODE` | no | `local` | `local` or `ssh` |
| `WOL_BROADCAST_IP` / `WOL_BROADCAST_PORT` | no | `255.255.255.255` / `9` | Local UDP destination |
| `WOL_SSH_HOST`, `WOL_SSH_USER` | SSH | — | Dedicated sender endpoint and account |
| `WOL_SSH_KEY`, `WOL_SSH_KNOWN_HOSTS` | SSH | — | Absolute local key and host-key files |
| `WOL_SSH_INTERFACE` | SSH | — | Interface used by the sender |
| `WOL_SSH_EXECUTABLE` | no | `/usr/local/sbin/remote-wol-sender` | Remote helper path |

Generate a token with `openssl rand -hex 32`. Enable at least one reachability probe.

## Install

```sh
sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin remote-wol-gateway
sudo install -m 0755 remote-wol-gateway /usr/local/sbin/remote-wol-gateway
sudo install -d -o remote-wol-gateway -g remote-wol-gateway -m 0700 /etc/remote-wol-gateway
sudo install -m 0600 remote-wol-gateway.env.example /etc/remote-wol-gateway/remote-wol-gateway.env
sudo install -m 0644 remote-wol-gateway.service /etc/systemd/system/remote-wol-gateway.service
```

In SSH mode, put the private key and `known_hosts` in `/etc/remote-wol-gateway`, readable only by the service account. On the sender host, install the helper and restrict the public key to it:

```sh
sudo install -m 0755 remote-wol-sender /usr/local/sbin/remote-wol-sender
# authorized_keys prefix:
restrict,command="/usr/local/sbin/remote-wol-sender" ssh-ed25519 AAAA...
```

The dedicated sender account must be allowed to execute `/usr/sbin/ether-wake` on the configured interface. The gateway performs a `--check` call at startup and exits with code `3` when the helper, interface, or SSH policy is not usable.

Edit the installed environment file, then enable the service:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now remote-wol-gateway.service
sudo journalctl -u remote-wol-gateway.service
```

## API

Set the same token in the calling shell without printing it:

```sh
read -rsp 'WoL token: ' WOL_TOKEN; export WOL_TOKEN; echo
curl -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/status
curl -X POST -H "Authorization: Bearer $WOL_TOKEN" http://127.0.0.1:18080/wol
```

| Request | Success | Other results |
|---|---|---|
| `GET /status` | `200` with probe results | `401`, `404`, or `405` |
| `POST /wol` | `200` when already/now online; `202` when sent but still offline | `409` wake already running; `502` send failed |

Responses and access logs are JSON. Authentication headers and token values are never logged.

## Test and remove

```sh
python3 -m unittest discover -s tests -v
```

To remove the service, disable it before deleting the unit, executable, environment directory, and any sender-host key authorization. No persistent application data is created.

If startup fails, check the journal and run the configured SSH helper manually with `--check <interface>`. A `202` response means the packet was sent but none of the configured probes succeeded before the deadline.

## Limitations

- Packet delivery does not prove that firmware or the operating system completed startup
- ICMP-only checks produce false negatives when ping is blocked
- Tray, browser, and other user-facing access should go through a separate trusted HTTPS or tunnel layer
