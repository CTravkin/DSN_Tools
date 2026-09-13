# MSStore EXE Launcher

[English](README.md) | [Русский](README.ru.md)

[К DSN Tools](../README.ru.md)

Собирает автономные Windows EXE для пакетных, настольных и tray-приложений.

## Функции

- Запускает пакетное приложение по точному AUMID или уникальному имени из `Get-StartApps`
- Активирует существующее окно настольного приложения до запуска нового процесса
- Вызывает настроенное действие в tray, если подходящего окна нет

## Стек

Windows PowerShell 5.1, компилятор C# из .NET Framework, Win32 API для окон и UI Automation.

## Требования

- Windows 10 или 11
- `csc.exe` в `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` или `Framework\v4.0.30319`
- Основной сборщик: точный AUMID или уникальное имя зарегистрированного приложения
- Сборщики desktop и tray: абсолютный путь к исполняемому файлу и имя процесса
- Tray-сборщик: точные доступные имена иконки и пункта меню на активном языке Windows
- Необязательный существующий файл `.ico`

Значения параметров сборки остаются видимыми внутри созданного EXE. Не помещай в них секреты.

## Эксплуатация

### Сборка

#### Лаунчер MS Store

```powershell
.\Build-Launcher.ps1 `
  -AppId 'Example.Package_123!App' `
  -OutputPath "$env:USERPROFILE\Desktop\Example.exe" `
  -IconPath 'C:\Path\Example.ico'
```

Установленное приложение также можно выбрать по точному уникальному имени:

```powershell
Get-StartApps
.\Build-Launcher.ps1 -AppName 'Exact registered name' -OutputPath '.\Example.exe'
```

#### Лаунчер настольного приложения

```powershell
.\Extras\Desktop_EXE_Launcher\Build-DesktopLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -WindowClass 'ExampleWindowClass' `
  -WindowTitle 'Example' `
  -Arguments '--profile default' `
  -OutputPath '.\Example Desktop.exe'
```

`WindowClass` и `WindowTitle` необязательны. `-IncludeHiddenWindow` разрешает выбрать подходящее скрытое окно.

#### Tray-лаунчер

```powershell
.\Extras\Tray_EXE_Launcher\Build-TrayLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -TrayIconName 'Example' `
  -TrayMenuItemName 'Open' `
  -OutputPath '.\Example Tray.exe'
```

Необязательные параметры задают фильтры окна, фиксированные аргументы, число попыток, задержку между ними и иконку.

### Проверка

Лаунчеры Store поддерживают `--print-aumid`, а desktop- и tray-лаунчеры — `--print-config`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LauncherBuilders.ps1
```

## Ограничения

- Активация окна зависит от ограничений Windows на перевод фокуса
- Tray-автоматизация зависит от имен UI Automation, языка интерфейса и поведения приложения
- Тестовые сборки не проверяют установленные приложения и реальные tray-иконки
