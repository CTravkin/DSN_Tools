# Syncthing ACL Refresh

[English](README.md) | [Русский](README.ru.md)

[Back to DSN Tools](../README.md)

`syncthing-acl-refresh` reconciles named POSIX ACL entries with folders and effective ignore rules read from a local Syncthing instance.

Managed users receive access to included objects and lose only their named ACL entries on excluded objects. Ownership, base permissions, unrelated ACL entries, contents, and symlinks are preserved. Symlink escapes and ACL-mask changes that would widen unrelated access are rejected.

## Stack

Python standard library, SQLite, systemd, POSIX ACL tools, and inotify-tools.

## Requirements

- Linux with Python 3.10 or newer and systemd
- Root privileges
- `getfacl`, `setfacl`, and `inotifywait`
- Syncthing GUI using HTTPS on a loopback IP
- A root-owned PEM copy of the Syncthing GUI certificate
- Existing accounts for every managed user

CLI options override the corresponding environment values.

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `ACL_USERS` | yes | — | Comma-separated managed users |
| `SYNCTHING_USER` | no | `syncthing` | Syncthing service account |
| `SYNCTHING_CONFIG` | no | auto-discovered | Absolute path to `config.xml` |
| `STATE_PATH` | no | `/var/lib/syncthing-acl-refresh/state.sqlite3` | SQLite cache |
| `TLS_CERTIFICATE` | no | `/etc/syncthing-acl-refresh/https-cert.pem` | Pinned GUI certificate |
| `REFRESH_HOURS` | no | `3` | Full-scan interval; must divide 24 |
| `MISSING_RECHECK_SECONDS` | no | `60` | Missing-root retry interval, 1–3600 seconds |

See [`syncthing-acl-refresh.env.example`](syncthing-acl-refresh.env.example).

## Integrations

The worker reads Syncthing's XML configuration and expanded ignore rules from its loopback HTTPS API. The API key remains in Syncthing's configuration.

## Operations

### Installation

```sh
sudo install -m 0755 syncthing-acl-refresh /usr/local/sbin/syncthing-acl-refresh
sudo install -d -m 0700 /etc/syncthing-acl-refresh /var/lib/syncthing-acl-refresh
sudo install -m 0600 syncthing-acl-refresh.env.example /etc/syncthing-acl-refresh/syncthing-acl-refresh.env
sudo install -m 0644 syncthing-acl-refresh.service /etc/systemd/system/syncthing-acl-refresh.service
sudo install -m 0600 /path/to/syncthing-https-cert.pem /etc/syncthing-acl-refresh/https-cert.pem
```

Edit the installed environment file. Replace the pinned certificate whenever Syncthing's GUI certificate changes.

### Run

```sh
sudo /usr/local/sbin/syncthing-acl-refresh --scan
sudo /usr/local/sbin/syncthing-acl-refresh --scan --force

sudo systemctl daemon-reload
sudo systemctl enable --now syncthing-acl-refresh.service
sudo journalctl -u syncthing-acl-refresh.service
```

`--scan` runs once. `--force` bypasses the metadata cache and reads ACLs again. Continuous mode uses inotify, periodic full scans, SQLite metadata caching, and retry backoff.

### Verification

```sh
sudo ACL_TEST_USERS=root,nobody python3 -m unittest discover -s tests -v
```

Integration tests require root, two existing users, `getfacl`, `setfacl`, `runuser`, and `openssl`. Select other users through `ACL_TEST_USERS`.

## Limitations

- Hostnames, non-loopback GUI addresses, and plain HTTP are rejected
- Existing default ACLs may affect permissions inherited by new children
- Special files never receive managed access
