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
| `ACL_READONLY_DIRECTORIES` | no | empty | Comma-separated absolute directories that receive read/search access without write |
| `ACL_READONLY_TREES` | no | empty | Comma-separated absolute subtrees with read-only managed access |

The allowlist format is `folder-id=/absolute/path`, one entry per folder that this utility should manage. The file must be owned by root and not writable by group or others. Each listed ID and path must match Syncthing configuration; unlisted Syncthing folders are ignored. Managed folder paths must not overlap.

CLI options override environment-file values. `--env-file` is intended for direct invocations; systemd loads the installed environment file itself.

Missing, malformed, or inconsistent ignore API responses stop reconciliation before ACL changes. Empty policies, including comment-only include files, remain valid. Effective patterns require a nonempty `expanded` response.

`ACL_READONLY_DIRECTORIES` (CLI: `--readonly-directories`) applies only to the exact listed directories, which must exist inside managed folders without symlinks. Managed users receive `r-x`, and the access ACL mask has no write bit. Ignore rules and traversal-only access take precedence over this setting. Descendants follow their normal ignore/access policy; default ACL inheritance remains unchanged. A conflicting unmanaged writer causes an error instead of silently revoking its permissions. The setting is included in reconciliation decisions, so adding or removing it takes effect without `--force`.

`ACL_READONLY_TREES` (CLI: `--readonly-trees`) applies to the listed directories and all included descendants. Files receive `r--`, directories and managed default ACL entries receive `r-x`. Ignore and traversal policies retain priority; a recursive policy takes precedence over an exact-directory setting. Unrelated users retain their effective permissions, including write access. Unneeded mask write bits are removed when doing so preserves unrelated access.

All access modes check managed file owners before changing ACLs: incompatible owner permissions cause an error without rewriting the owner's rights. Read-only modes reject UID 0 and writable managed owners; ACLs cannot impose a read-only boundary on those principals. Exclusion removes managed ACL entries, and does not revoke access already held through ownership. The upgrade invalidates old cache timestamps once while retaining revocation provenance; subsequent runs reuse the cache. Files created with restrictive modes or changed by another service may need the next reconciliation to restore read access.

POSIX ACL masks appear in the group mode bits reported by `stat`. Granting a named user read access to a `0600` file normally makes that mode `0640`. Applications that demand private modes, including OpenSSH private-key loading, can reject such files. Recursive read-only ACLs therefore do not provide a transparent backup view of arbitrary private system files; use a separate export when original mode bits must remain untouched.

Directories needed to reach possible negated matches receive `r-x`: Syncthing's scanner and watcher must list them. This does not grant access to ignored files. Nested negations can require directory listing across the managed tree because Syncthing cannot prune those directories. When upgrading from execute-only traversal, run one full canonical reconciliation with `--force` to refresh cached ACLs; subsequent runs use the normal cache.

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

Revocation removes a utility-created default ACL scaffold only while its base owner/group/other entries and mask match the last recorded directory policy and no unrelated named entries remain. Later administrator changes are preserved. If the previous policy cannot establish the expected mask, the base scaffold is kept.

## Test

```sh
sudo ACL_TEST_USERS=nobody,daemon python3 -m unittest discover -s tests -v
```

ACL integration tests require root, two existing non-root managed users, one additional local account, `getfacl`, `setfacl`, `runuser`, and `openssl`. The additional account is selected automatically and is never granted access.

## Limitations

- An object moved outside a managed root may retain its ACL because state is path-based
- Hard links share one inode, so changing an in-root link also changes links to that inode elsewhere
- Existing unrelated default ACLs remain in effect
- Special files never receive managed access
- When reverting to an older utility, restore its matching state snapshot; older code cannot read newer recursive read-only access levels
