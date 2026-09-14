# Windows Icon Recovery

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.md)

Windows Icon Recovery captures, audits, restores, and rolls back folder `IconResource` and shortcut `.lnk` `IconLocation` assignments from a versioned JSON manifest.

Restore is fail-closed: every target and icon-source file is checked before any write. Missing assignments and incorrect Explorer attributes are repairable; a different non-empty icon is a conflict and nothing is changed. Every affected file and its attributes are backed up before restoration.

## Requirements

- Windows 10 or 11 and Windows PowerShell 5.1
- Permission to update target folders, `desktop.ini`, `.lnk` files, and their attributes
- Absolute target and icon-source paths after environment expansion
- A writable backup directory

The tool verifies that an icon source file exists. It does not validate that a requested resource index exists inside an EXE or DLL.

## Manifest

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

The manifest must contain at least one unique target. Paths may retain environment variables for portability. Manifests normally contain machine-specific paths; review them before committing or sharing. See [`examples/icon-manifest.example.json`](examples/icon-manifest.example.json).

## Capture and audit

```powershell
.\Export-IconManifest.ps1 `
  -OutputPath .\icons.json `
  -Folder '%USERPROFILE%\Example' `
  -Shortcut '%USERPROFILE%\Desktop\Example.lnk'

.\Test-IconAssignments.ps1 -ManifestPath .\icons.json
```

Audit exits `0` when the manifest matches and `1` for any problem or input error. Output is JSON with per-target details.

## Restore and rollback

Preview a restore, then apply it:

```powershell
.\Restore-IconAssignments.ps1 `
  -ManifestPath .\icons.json `
  -BackupRoot "$env:USERPROFILE\Icon Recovery Backups" `
  -WhatIf

.\Restore-IconAssignments.ps1 `
  -ManifestPath .\icons.json `
  -BackupRoot "$env:USERPROFILE\Icon Recovery Backups"
```

Restore exits `0` after a successful verification, `2` when preflight finds a conflict, missing target, or missing icon source, and `1` on an execution or post-verification failure. A mid-operation failure triggers automatic rollback.

The returned backup path contains copied files, SHA-256 hashes, and original file/folder attributes. Roll it back explicitly with:

```powershell
.\Undo-IconRecovery.ps1 -BackupPath 'C:\Path\To\Backup'
```

Both restore and rollback support `-WhatIf` and `-Confirm`. Explorer receives item-level change notifications; the utility does not clear the icon cache or restart Explorer.

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-IconRecovery.ps1
```

## Troubleshooting

- `IconConflict`: change the manifest intentionally or clear the assignment yourself; the utility will not overwrite it
- `AttributeMismatch`: run restore to repair `desktop.ini` Hidden/System and folder ReadOnly flags
- An unchanged visible icon can be an Explorer cache delay; reopen the folder before considering broader cache repair
