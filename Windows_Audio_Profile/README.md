# Windows Audio Profile

[DSN Tools](../README.md) | English | [Русский](README.ru.md)

Windows Audio Profile exports the registered playback and recording endpoints to JSON, validates a deliberately edited profile, applies it, and can restore the previous state.

This is an administrative script utility, not an audio control panel or an installer. Its intended workflow is **export, edit, test, preview, apply**. Do not write device identity data from scratch unless you understand the matching rules.

## Features

- exports active, disabled, and disconnected playback and recording endpoints
- manages display names, icons, endpoint visibility, volume, mute, and shared-mode format
- records and applies default-device priority for Console, Multimedia, and Communications
- matches recreated endpoints by Windows Stable ID when available, with a conservative legacy fallback
- validates JSON types and profile consistency before changing Windows
- creates a restorable backup and verifies the state after Apply and Undo
- supports human-readable output and JSON output with stable exit codes

The utility does not install drivers, pair Bluetooth devices, disable physical PnP devices, or manage driver-specific effects.

## Stack

- 64-bit Windows PowerShell 5.1
- C# Core Audio interop compiled at runtime by PowerShell
- JSON profile plus [JSON Schema](audio-profile.schema.json)

No external PowerShell modules or installed .NET SDK are required.

## Platforms

The supported target is x64 Windows 10 and Windows 11. The current implementation has been exercised on Windows 11 25H2, build 26200.9550. Other Windows builds and audio drivers should be treated as compatible targets, not as verified combinations.

[`StableId`](https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-stableid) is a Windows 11 24H2 or later property. It is exported only when Windows provides it for the endpoint. Profiles remain usable without it through the stricter legacy fingerprint.

Priority storage and some endpoint properties are Windows implementation details rather than a complete public administration API. Always run `Test` and `-WhatIf` after moving the utility to another Windows build or machine.

## Requirements

- a trusted local checkout of the repository
- 64-bit `powershell.exe`
- UAC approval for Apply and Undo when changes are required
- referenced icon files or resources already present on the target computer

Run commands from the `Windows_Audio_Profile` directory.

## Data exchange

### Profile JSON

Start by exporting the current computer. Keep the generated fields under `target` and `match` unchanged; they identify the Windows installation and its endpoints. Edit `profile`, `required`, `settings`, and `priority`.

The profile uses patch semantics: a missing setting is left unchanged. For example, this changes only the display name, volume, mute state, and format:

```json
"settings": {
  "name": "Studio microphone",
  "volume": {
    "percent": 80,
    "muted": false
  },
  "format": {
    "channels": 1,
    "sampleRateHz": 48000,
    "bitsPerSample": 24,
    "encoding": "pcm"
  }
}
```

Important fields:

- `name` is the first-line endpoint name in the classic Sound panel; driver and PnP names are not changed
- `icon` references an existing `.ico`, DLL, or EXE resource; the utility does not copy the file
- `enabled` controls endpoint visibility in the classic Sound panel, not the physical device
- `volume` accepts either `percent` or `decibels`, plus an independent `muted` value
- `format` sets the shared-mode channel count, sample rate, bit depth, encoding, and optional channel mask
- `required: false` turns a missing endpoint into a warning instead of an error

Priority arrays are ordered from least to most preferred:

```json
"leastToMostPreferred": [
  "monitor",
  "speakers",
  "headphones"
]
```

`allRoles` applies one order to Console, Multimedia, and Communications. Entries under `roles` replace it for one role. If priority is configured for a playback or recording flow, its list must contain every eligible endpoint in that flow. Windows endpoints marked `NeverSetAsDefaultEndpoint` are excluded.

Use [audio-profile.example.json](audio-profile.example.json) as a structural reference and [audio-profile.schema.json](audio-profile.schema.json) for editor validation. The example contains placeholder identities and is not intended to be applied directly.

### Device matching

Matching is fail-closed and follows this order:

1. exact endpoint ID plus the exported fingerprint
2. exact, case-sensitive `StableId`, when present
3. at least two matching legacy identity anchors such as PnP Container ID, Device Instance ID, or Hardware ID

Display names are never identity keys. Zero or multiple candidates are errors. `StableId` is an opaque Windows value: do not normalize, recase, or construct it.

Profiles are bound to the source Windows installation by a SHA-256 hash of `MachineGuid`. `-IgnoreMachineBinding` permits a deliberate migration, but does not relax endpoint matching.

## Operations

### 1. Export

Export all registered endpoints, including disabled and disconnected ones:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Export-AudioProfile.ps1 `
  -OutputPath .\my-audio-profile.json
```

Keep this original export until the edited profile has been applied and verified.

### 2. Edit

Edit only the settings and priority you intend to manage. Remove a setting rather than copying its current value when that setting should remain unmanaged.

Do not reorder or rename device keys after referring to them from `priority`. Do not replace generated identity fields with display names.

### 3. Test

Validate the document and resolve its devices without changing Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json
```

`Test` and `Apply` validate raw JSON token types before PowerShell conversion. Values such as `"false"` and `"50"` are rejected where a Boolean or number is required.

### 4. Preview

Inspect the exact apply plan without elevation or a backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json -WhatIf
```

Add `-Json` when another tool will consume the result.

### 5. Apply

For interactive use, start with `Strict`. It rolls the profile back if an operation fails:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json -ApplyMode Strict
```

`BestEffort` keeps independent successful changes and reports the failures. Use it only when a partial result is acceptable.

### 6. Undo

Apply reports the created backup path. Restore it with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Undo-AudioProfile.ps1 `
  -BackupPath .\Backups\20260927-120000-1234abcd
```

Undo restores and verifies only the fields and priority flows touched by the source profile.

### Output and exit codes

Add `-Json` to any public command for machine-readable output.

- `0` — success
- `1` — failure
- `2` — partial `BestEffort` result

### Elevation, backup, and recovery

Apply and Undo request UAC only when a change is required. Before Apply, every affected property must be readable for backup. The default backup is `Backups/<timestamp>-<id>/state.json`; use `-BackupRoot` to choose another directory.

Normal endpoint properties use Core Audio. Exact priority levels require a short-lived scheduled task under SYSTEM and a process token from the Windows Modules Installer (`TrustedInstaller`) service. Code and data are copied to an ACL-protected ProgramData staging directory and verified by SHA-256 before privileged execution. The helper has a finite timeout. The task, staging directory, and any temporary service start are cleaned up afterward; no persistent service or background process is installed.

A profile or backup is SHA-256-bound to the snapshot taken before UAC. A restore mismatch is reported as a failure.

## Limitations

- Windows can open an audio stream only for an active endpoint. To change volume, the utility may temporarily enable a disabled endpoint and then restore its requested final state. A physically unavailable Bluetooth endpoint can still reject the operation.
- Drivers can reject or later replace a shared-mode format. Alternative A2DP drivers are a common example. Apply reads the state back, but cannot guarantee persistence after a reconnect.
- Fixed-volume virtual endpoints can report a `0 dB..0 dB` range; percentage volume is not meaningful for them.
- Per-channel levels, Microphone Boost, driver-specific effects, physical PnP state, driver installation, and Bluetooth pairing are outside version 1.
- Sound control panels can cache names and icons until reopened.
- This is an unsigned script utility. Protected staging prevents modification after privileged code reaches staging, but does not authenticate the checkout itself. Review updates and keep the repository in a trusted location before approving UAC.

## Verification

The normal suite is read-only and does not require elevation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-WindowsAudioProfile.ps1
```

`Tests\Test-ElevatedApply.ps1` is an explicit integration test. Run it from an elevated Windows PowerShell session only when temporary priority and endpoint-name changes are acceptable. It verifies protected staging, strict rollback, a BestEffort priority failure, actual state after Apply and Undo, restoration of the original state, and cleanup.
