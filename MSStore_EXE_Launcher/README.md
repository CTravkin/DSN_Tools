# MSStore EXE Launcher

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.md)

MSStore EXE Launcher builds a small standalone EXE that opens a packaged Windows application by its exact application user model ID (AUMID). This is useful where a tool accepts executable paths but cannot launch `shell:AppsFolder` entries directly.

The main builder targets packaged applications. [`Extras`](Extras/) retains two narrower techniques for ordinary desktop applications: activating an existing window and invoking a tray-menu action before starting another process.

## Requirements

- Windows 10 or 11 and Windows PowerShell 5.1
- .NET Framework C# compiler under `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` or `Framework\v4.0.30319`
- Optional existing `.ico` file for the generated EXE
- Tray mode: exact UI Automation names in the current Windows display language

Build-time values are embedded in the EXE and visible to anyone who can inspect it. Do not use them for secrets.

## Packaged application launcher

List registered names and AUMIDs with `Get-StartApps`, then build by exact AUMID:

```powershell
Get-StartApps
.\Build-Launcher.ps1 `
  -AppId 'Example.Package_123!App' `
  -OutputPath "$env:USERPROFILE\Desktop\Example.exe" `
  -IconPath 'C:\Path\Example.ico'
```

An exact unique registered name can be used instead:

```powershell
.\Build-Launcher.ps1 -AppName 'Exact registered name' -OutputPath '.\Example.exe'
```

The builder rejects malformed or ambiguous AUMIDs. Existing output is not replaced unless `-Force` is supplied. The generated EXE returns `0` after handing the request to the Windows shell and `1` if launch setup fails. `--print-aumid` prints the embedded ID without launching.

## Extra: desktop window launcher

```powershell
.\Extras\Desktop_EXE_Launcher\Build-DesktopLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -WindowClass 'ExampleWindowClass' `
  -WindowTitle 'Example' `
  -Arguments '--profile default' `
  -OutputPath '.\Example Desktop.exe'
```

The launcher activates the first matching top-level window or starts the configured executable. `WindowClass` and `WindowTitle` are optional; `-IncludeHiddenWindow` permits hidden matches. Exit codes: `0` success, `1` start failure, `2` missing target, `3` Windows rejected foreground activation.

## Extra: tray action launcher

```powershell
.\Extras\Tray_EXE_Launcher\Build-TrayLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -TrayIconName 'Example' `
  -TrayMenuItemName 'Open' `
  -OutputPath '.\Example Tray.exe'
```

If no matching window exists, the launcher looks only in Windows notification areas, opens the matching icon's context menu, invokes the nearest matching menu item, and restores the pointer position. If neither a window nor tray icon exists, it starts the process. Exit code `4` means the tray action or resulting activation failed; codes `0`–`3` match desktop mode.

Desktop and tray launchers support `--print-config`. All builders accept `-Force` for deliberate replacement.

## Test and remove

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LauncherBuilders.ps1
```

The tests compile all three variants and verify embedded configuration and decision logic. They do not automate a real installed Store application or notification icon.

Generated launchers have no installer or persistent state. Remove an EXE by deleting it.

## Troubleshooting

- An ambiguous `-AppName` must be replaced with the exact `-AppId`
- Exit `3` is usually a Windows foreground-focus restriction, not a build error
- Tray names depend on application accessibility metadata and display language; inspect the live UI Automation names when exit `4` persists
