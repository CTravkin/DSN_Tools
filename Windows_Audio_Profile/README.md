# Windows Audio Profile

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.md)

Windows Audio Profile is an administrative tool for exporting, validating, applying, and rolling back Windows playback and recording endpoint settings through an explicit JSON profile.

It manages registered audio endpoints, not physical devices. Driver installation, Bluetooth pairing, PnP state, per-channel levels, Microphone Boost, and driver-specific effects are outside its scope.

## Features

- exports active, disabled, and disconnected playback and recording endpoints
- manages display names, icons, endpoint visibility, volume, mute, and shared-mode format
- applies default-device priority for Console, Multimedia, and Communications
- matches recreated endpoints by Windows Stable ID or a conservative legacy fingerprint
- validates and previews a profile before changes, then backs up, verifies, rolls back, or restores the affected state
- provides human-readable and JSON output with stable exit codes

## Stack

- 64-bit Windows PowerShell 5.1
- C# Core Audio interop compiled at runtime
- JSON profile validated against [JSON Schema](audio-profile.schema.json)

No external PowerShell modules or installed .NET SDK are required.

## Platforms

The target platforms are x64 Windows 10 and Windows 11. The current release has been exercised on Windows 11 25H2, build 26200.9550; other Windows builds and audio drivers are supported targets rather than verified combinations.

Windows 11 24H2 introduced `PKEY_AudioEndpoint_StableId`. Not every endpoint is guaranteed to provide it, so the tool retains stricter legacy matching. Default-device priority and some endpoint properties rely on Windows implementation details; validate and preview a profile again after changing Windows builds, drivers, or hardware.

## Requirements

- a trusted local checkout
- 64-bit `powershell.exe`
- UAC approval when Apply or Undo requires changes
- existing local files or resources for any configured icons

Run commands from the `Windows_Audio_Profile` directory.

## Data exchange

The tool reads and writes a versioned JSON profile. Export a profile from the target computer and edit that file; do not construct device identities manually.

| Section | Purpose |
|---|---|
| `target` | Identifies the source Windows installation |
| `devices[].match` | Contains generated endpoint identities; normally leave these values unchanged |
| `devices[].settings` | Selects the name, icon, visibility, volume, mute state, and format to manage |
| `priority` | Orders eligible playback and recording endpoints from least to most preferred |

The profile uses patch semantics: a missing setting remains unchanged. Set `required` to `false` only when an absent endpoint should produce a warning instead of an error.

Device matching is fail-closed:

1. exact endpoint ID and exported fingerprint
2. exact case-sensitive `StableId`, when available
3. at least two matching legacy identity anchors, such as Container ID, Device Instance ID, or Hardware ID

Display names are never identity keys. Zero or multiple matches are errors. Profiles are bound to the source installation by a SHA-256 hash of `MachineGuid`; `-IgnoreMachineBinding` permits a deliberate migration without relaxing endpoint matching.

See [the example profile](audio-profile.example.json) for the complete structure. Its identities are placeholders and must not be applied directly.

## Operations

### Usage

1. Export the current endpoint inventory:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Export-AudioProfile.ps1 `
     -OutputPath .\my-audio-profile.json
   ```

2. Edit only `settings`, `required`, profile metadata, and `priority`. Remove settings that should remain unmanaged. Keep the original export until the edited profile has been applied and verified.

3. Validate device matching and preview the apply plan without changing Windows:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-AudioProfile.ps1 `
     -ProfilePath .\my-audio-profile.json

   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
     -ProfilePath .\my-audio-profile.json -WhatIf
   ```

4. Apply in `Strict` mode for automatic rollback after an error:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
     -ProfilePath .\my-audio-profile.json -ApplyMode Strict
   ```

   `BestEffort` retains independent successful changes and returns a partial result. Use it only when partial application is acceptable.

5. Apply reports the created backup path. Restore that state with:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Undo-AudioProfile.ps1 `
     -BackupPath .\Backups\20260927-120000-1234abcd
   ```

Add `-Json` to public commands for machine-readable output. Exit codes are `0` for success, `1` for failure, and `2` for a partial `BestEffort` result.

Apply and Undo request UAC only when changes are required. Apply first verifies that affected values can be backed up and writes `state.json` under `Backups/<timestamp>-<id>` by default. Exact priority changes use a short-lived protected helper under SYSTEM and `TrustedInstaller`; its scheduled task, staging directory, and temporary service start are cleaned up after the operation.

Operational limits:

- a physically unavailable Bluetooth endpoint can reject a volume operation
- a driver can reject or later replace a shared-mode format, including after reconnecting through an alternative A2DP driver
- fixed-volume virtual endpoints can expose a meaningless `0 dB..0 dB` range
- Sound control panels can cache names and icons until reopened
- the scripts are unsigned; review updates and keep the checkout in a trusted location before approving UAC

### Verification

The normal suite is read-only and does not require elevation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-WindowsAudioProfile.ps1
```

`Tests\Test-ElevatedApply.ps1` is an explicit integration test. Run it only from an elevated Windows PowerShell session when temporary endpoint-name and priority changes are acceptable. It restores the original state and checks cleanup.

## Links

- [Profile example](audio-profile.example.json)
- [Profile schema](audio-profile.schema.json)
- [Microsoft: PKEY_AudioEndpoint_StableId](https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-stableid)
