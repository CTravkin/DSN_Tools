# Syncthing ACL Refresh

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.md)

`syncthing-acl-refresh` reconciles named POSIX ACL entries with local Syncthing folders and their effective ignore rules. Included files receive the configured users' access; excluded files lose only ACL entries managed by this utility.

The process runs as root and manages only folders listed by exact Syncthing folder ID and absolute path in a root-owned allowlist. It rejects the filesystem root, symlinks in a managed path, non-loopback Syncthing endpoints, plain HTTP, and ACL mask changes that would widen unrelated access.

## Requirements

- Linux, Python 3.10+, and systemd
- `getfacl` and `setfacl`
- Syncthing GUI HTTPS bound to a loopback IP
- A root-owned copy of the Syncthing GUI certificate
- Existing local accounts named in `ACL_USERS`

## Configuration

Copy [`syncthing-acl-refresh.env.example`](syncthing-acl-refresh.env.example) and [`folders.conf.example`](folders.conf.example).

| Variable | Required | Default | Purpose |
|---|---:|---|---|
| `ACL_USERS` | yes | — | Comma-separated accounts whose named ACL entries are managed |
| `SYNCTHING_USER` | no | `syncthing` | Account whose Syncthing configuration is read |
| `SYNCTHING_CONFIG` | no | discovered from that account | Absolute `config.xml` path |
| `STATE_PATH` | no | `/var/lib/syncthing-acl-refresh/state.sqlite3` | Reconciliation and revocation state |
| `TLS_CERTIFICATE` | no | `/etc/syncthing-acl-refresh/https-cert.pem` | Pinned GUI certificate |
| `FOLDER_ALLOWLIST` | no | `/etc/syncthing-acl-refresh/folders.conf` | Root-controlled folder allowlist |

The allowlist format is `folder-id=/absolute/path`, one entry per folder that this utility should manage. The file must be owned by root and not writable by group or others. Each listed ID and path must match Syncthing configuration; unlisted Syncthing folders are ignored. Managed folder paths must not overlap.

CLI options override environment-file values. `--env-file` is intended for direct invocations; systemd loads the installed environment file itself.

Legacy state is migrated with the current `ACL_USERS` value. Revoke recorded ACLs before upgrading if the managed user list also changes.

## Install and run

```sh
sudo install -m 0755 syncthing-acl-refresh /usr/local/sbin/syncthing-acl-refresh
sudo install -d -m 0700 /etc/syncthing-acl-refresh /var/lib/syncthing-acl-refresh
sudo install -m 0600 syncthing-acl-refresh.env.example /etc/syncthing-acl-refresh/syncthing-acl-refresh.env
sudo install -m 0600 folders.conf.example /etc/syncthing-acl-refresh/folders.conf
sudo install -m 0600 /path/to/syncthing-https-cert.pem /etc/syncthing-acl-refresh/https-cert.pem
sudo install -m 0644 syncthing-acl-refresh.service /etc/systemd/system/syncthing-acl-refresh.service
sudo install -m 0644 syncthing-acl-refresh.timer /etc/systemd/system/syncthing-acl-refresh.timer
```

Edit both installed configuration files, then run a one-shot check before enabling the service:

```sh
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --force

sudo systemctl daemon-reload
sudo systemctl enable --now syncthing-acl-refresh.timer
sudo journalctl -u syncthing-acl-refresh.service
```

The timer runs a full reconciliation every 15 minutes. Default directory ACLs provide access to new children between runs; the next pass corrects any drift.

## Audit, revoke, and uninstall

The command exits `0` when reconciliation succeeds and `1` when any path fails. `--force` bypasses the metadata cache.

Before removing a folder from the allowlist or uninstalling the utility, stop the service and revoke every ACL entry recorded in its state:

```sh
sudo systemctl disable --now syncthing-acl-refresh.timer
sudo /usr/local/sbin/syncthing-acl-refresh \
  --env-file /etc/syncthing-acl-refresh/syncthing-acl-refresh.env \
  --revoke-all
```

Exit code `1` means some recorded path could not be safely identified or cleaned. Keep the state database and resolve those paths before deleting the installation.

## Test

```sh
sudo ACL_TEST_USERS=root,nobody python3 -m unittest discover -s tests -v
```

ACL integration tests require root, two existing users, one additional local account, `getfacl`, `setfacl`, `runuser`, and `openssl`. The additional account is selected automatically and is never granted access.

## Limitations

- An object moved outside a managed root may retain its ACL because state is path-based
- Hard links share one inode, so changing an in-root link also changes links to that inode elsewhere
- Existing unrelated default ACLs remain in effect
- Special files never receive managed access
