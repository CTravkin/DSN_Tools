# Windows Audio Profile

[English](README.md) | [Русский](README.ru.md)

Exports Windows audio endpoint settings to JSON, validates an edited profile, applies it, and restores the previous state.

The utility manages registered playback and recording endpoints. It does not install drivers, pair Bluetooth devices, or disable physical PnP devices.

## Requirements

- Windows 10 or Windows 11
- 64-bit Windows PowerShell 5.1
- Administrator approval for `Apply` and `Undo`

No external PowerShell modules or installed .NET SDK are required.

## Commands

Export every registered endpoint, including disabled and disconnected endpoints:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Export-AudioProfile.ps1 `
  -OutputPath .\my-audio-profile.json
```

Validate an edited profile without changing Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json
```

Preview the apply plan without elevation or a backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json -WhatIf -Json
```

Apply all requested settings. `Strict` rolls back after an error; `BestEffort` retains successful independent changes and reports the rest:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Apply-AudioProfile.ps1 `
  -ProfilePath .\my-audio-profile.json -ApplyMode Strict
```

Restore a backup reported by `Apply`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Undo-AudioProfile.ps1 `
  -BackupPath .\Backups\20260927-120000-1234abcd
```

Add `-Json` to public commands for machine-readable output. Exit code `0` means success, `1` means failure, and `2` means a partial `BestEffort` result.

## Profile behavior

The profile uses patch semantics. A missing device setting is left unchanged. `name` is the user-editable endpoint display name shown on the first line in the classic Sound panel; driver and PnP names are not changed.

`volume` accepts either `percent` or `decibels`, plus an independent `muted` value. `format` describes channels, sample rate, bit depth, encoding, and channel mask. Icons are references to existing `.ico`, DLL, or EXE resources; files are not copied.

`enabled` changes the endpoint state used by the classic Sound panel. It never disables the underlying PnP device or Bluetooth adapter.

Priority arrays are ordered from least to most preferred. `allRoles` covers Console, Multimedia, and Communications. Entries under `roles` replace the order for one role. If priority is present for a flow, it must list every eligible endpoint in that flow. Endpoints marked by Windows as `NeverSetAsDefaultEndpoint` are excluded. Verification checks both stored priority levels and the effective default endpoint for every configured role.

See [audio-profile.example.json](audio-profile.example.json) and [audio-profile.schema.json](audio-profile.schema.json).

`Test` and `Apply` validate JSON token types before PowerShell converts the document. Strings such as `"false"` or `"50"` are rejected where a Boolean or number is required.

## Device matching

The current endpoint ID is tried first. If Windows recreated the endpoint, the utility requires at least two exported stable identity anchors, such as the PnP container ID, device instance ID, or hardware IDs. Display names are never identity keys. Zero or multiple matches fail closed. Set `required` to `false` only when an absent device should produce a warning.

Exported profiles are bound to the current Windows installation by a SHA-256 hash of MachineGuid. `-IgnoreMachineBinding` is available for a deliberate migration; it does not relax device matching.

## Elevation and backups

`Apply` and `Undo` request UAC only when a change is required. The profile or backup is bound to its pre-UAC snapshot by SHA-256. Normal endpoint properties use Core Audio. Exact default priority levels require a short-lived scheduled task under SYSTEM and a process token from the Windows Modules Installer (`TrustedInstaller`) service. Priority code and data are copied to a temporary ACL-protected directory under ProgramData and verified by SHA-256 before privileged execution. The helper has a finite timeout. The task, staging directory, and any temporary service start are cleaned up after the operation; no service or background helper is installed.

Before changing anything, `Apply` verifies that every touched property can be backed up, then writes `state.json` under `Backups/<timestamp>-<id>` by default. Use `-BackupRoot` to select another location. `Undo` restores and verifies only the exact fields and priority flows touched by the source profile. A restore mismatch is reported as a failure.

## Limitations

- Windows can open an audio stream only for an active endpoint. The utility temporarily enables a disabled endpoint when volume must be changed, then restores the requested final state. A physically unavailable Bluetooth endpoint can still reject the operation.
- Drivers can reject or later replace a shared-mode format. Alternative A2DP drivers are a common example. `Apply` reads the state back and reports a mismatch; it cannot guarantee that a driver will preserve the value after reconnecting.
- Fixed-volume virtual endpoints can report a `0 dB..0 dB` range. Their percentage control is not meaningful.
- Per-channel levels, Microphone Boost, driver-specific effects, PnP state, driver installation, and Bluetooth pairing are outside version 1.
- Sound control panels can cache names and icons until reopened.
- Version 1 is a portable script utility, not a signed installer. Protected staging prevents modification after elevation begins, but the utility does not authenticate source scripts before launch. Keep the checkout in a trusted location and review updates before approving UAC.

## Tests

The normal suite is read-only and does not require elevation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-WindowsAudioProfile.ps1
```

`Tests\Test-ElevatedApply.ps1` is an explicit integration test. Run it from an elevated Windows PowerShell session only when temporary priority and endpoint-name changes are acceptable. It verifies protected staging, exercises strict rollback and a BestEffort priority failure, checks actual state after Apply and Undo, then restores the original state and checks cleanup.
