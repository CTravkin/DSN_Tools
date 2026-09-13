# MSStore EXE Launcher

[English](README.md) | [Русский](README.ru.md)

[Back to DSN Tools](../README.md)

Builds standalone Windows executables for packaged, desktop, and tray applications.

## Features

- Launches a packaged application by exact AUMID or unique `Get-StartApps` name
- Activates an existing desktop window before starting another process
- Invokes a configured tray action when no usable window exists

## Stack

Windows PowerShell 5.1, .NET Framework C# compiler, Win32 window APIs, and UI Automation.

## Requirements

- Windows 10 or 11
- `csc.exe` under `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` or `Framework\v4.0.30319`
- Main builder: an exact AUMID or unique registered application name
- Desktop and tray builders: an absolute executable path and process name
- Tray builder: exact accessible icon and menu-item names in the active Windows language
- Optional existing `.ico` file

Build-time values remain visible inside the generated executable. Do not embed secrets.

## Operations

### Build

#### MS Store launcher

```powershell
.\Build-Launcher.ps1 `
  -AppId 'Example.Package_123!App' `
  -OutputPath "$env:USERPROFILE\Desktop\Example.exe" `
  -IconPath 'C:\Path\Example.ico'
```

An installed application can also be selected by exact unique name:

```powershell
Get-StartApps
.\Build-Launcher.ps1 -AppName 'Exact registered name' -OutputPath '.\Example.exe'
```

#### Desktop launcher

```powershell
.\Extras\Desktop_EXE_Launcher\Build-DesktopLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -WindowClass 'ExampleWindowClass' `
  -WindowTitle 'Example' `
  -Arguments '--profile default' `
  -OutputPath '.\Example Desktop.exe'
```

`WindowClass` and `WindowTitle` are optional. `-IncludeHiddenWindow` allows a hidden matching window.

#### Tray launcher

```powershell
.\Extras\Tray_EXE_Launcher\Build-TrayLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -TrayIconName 'Example' `
  -TrayMenuItemName 'Open' `
  -OutputPath '.\Example Tray.exe'
```

Optional parameters set window filters, fixed arguments, retry count, retry delay, and icon.

### Verification

Generated Store launchers support `--print-aumid`; desktop and tray launchers support `--print-config`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LauncherBuilders.ps1
```

## Limitations

- Window activation is subject to Windows foreground-focus restrictions
- Tray automation depends on UI Automation names, display language, and application behavior
- Fixture tests do not exercise installed applications or live tray icons
