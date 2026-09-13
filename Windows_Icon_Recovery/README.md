# Windows Icon Recovery

[English](README.md) | [Русский](README.ru.md)

[Back to DSN Tools](../README.md)

Captures, audits, and restores folder `IconResource` and shortcut `.lnk` `IconLocation` values from a versioned JSON manifest.

Restoration changes only missing or empty assignments. A different non-empty icon is reported as a conflict. Every changed file is backed up with a SHA-256 checksum before writing, and the result is audited afterward.

## Stack

Windows PowerShell 5.1, Windows Shell COM automation, and Explorer shell notifications.

## Requirements

- Windows 10 or 11
- Permission to update the target `desktop.ini`, shortcut, and file attributes
- Absolute target and icon-source paths after environment expansion
- A writable backup directory for restoration

## Data exchange

The manifest uses this schema:

```json
{
  "version": 1,
  "folders": [
    { "path": "%USERPROFILE%\\Example", "icon": "%SystemRoot%\\system32\\shell32.dll,3" }
  ],
  "shortcuts": [
    { "path": "%USERPROFILE%\\Desktop\\Example.lnk", "icon": "%SystemRoot%\\system32\\shell32.dll,3" }
  ]
}
```

Targets must be unique. Environment variables remain unexpanded in the manifest. See [`examples/icon-manifest.example.json`](examples/icon-manifest.example.json).

Commands return structured JSON. Audit and restore results include problem or conflict details.

## Operations

### Usage

#### Capture

```powershell
.\Export-IconManifest.ps1 `
  -OutputPath .\icons.json `
  -Folder '%USERPROFILE%\Example' `
  -Shortcut '%USERPROFILE%\Desktop\Example.lnk'
```

#### Audit

```powershell
.\Test-IconAssignments.ps1 -ManifestPath .\icons.json
```

Exit code `0` means no problems; `1` means a problem or input error was found.

#### Restore

```powershell
.\Restore-IconAssignments.ps1 `
  -ManifestPath .\icons.json `
  -BackupRoot "$env:USERPROFILE\Icon Recovery Backups"
```

Exit code `0` means the restored state passed verification. Code `2` means a missing target or conflicting assignment; code `1` means an error or failed verification.

The returned backup directory contains a manifest and copies of changed files. To roll back, verify the recorded checksum and restore each copy to its `sourceFile`; remove files whose `existed` value is `false`. Folder attributes may need separate rollback because restoration can add the `ReadOnly` flag required by Explorer.

### Verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-IconRecovery.ps1
```

## Limitations

- Missing icon source files are reported but not restored
- Conflicting non-empty assignments are not overwritten
- Explorer may retain a visual cache after receiving an item refresh notification
