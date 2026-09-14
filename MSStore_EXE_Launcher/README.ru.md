# MSStore EXE Launcher

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.ru.md)

MSStore EXE Launcher собирает небольшой автономный EXE, который открывает пакетное приложение Windows по точному application user model ID (AUMID). Это нужно там, где программа принимает путь к EXE, но не умеет запускать записи `shell:AppsFolder` напрямую.

Основной сборщик предназначен для пакетных приложений. В [`Extras`](Extras/) сохранены два более узких приема для обычных desktop-приложений: активация существующего окна и вызов пункта tray-меню до запуска еще одного процесса.

## Требования

- Windows 10 или 11 и Windows PowerShell 5.1
- Компилятор C# из .NET Framework в `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319` или `Framework\v4.0.30319`
- Необязательный существующий `.ico` для созданного EXE
- Tray-режим: точные UI Automation имена на текущем языке Windows

Параметры сборки встраиваются в EXE и видны при его анализе. Не используй их для секретов.

## Лаунчер пакетного приложения

Получи зарегистрированные имена и AUMID через `Get-StartApps`, затем собери EXE по точному AUMID:

```powershell
Get-StartApps
.\Build-Launcher.ps1 `
  -AppId 'Example.Package_123!App' `
  -OutputPath "$env:USERPROFILE\Desktop\Example.exe" `
  -IconPath 'C:\Path\Example.ico'
```

Можно использовать точное уникальное зарегистрированное имя:

```powershell
.\Build-Launcher.ps1 -AppName 'Exact registered name' -OutputPath '.\Example.exe'
```

Сборщик отклоняет некорректные и неоднозначные AUMID. Существующий файл заменяется только с `-Force`. Созданный EXE возвращает `0` после передачи запуска Windows Shell и `1` при ошибке подготовки запуска. `--print-aumid` выводит встроенный ID без запуска приложения.

## Дополнение: desktop window launcher

```powershell
.\Extras\Desktop_EXE_Launcher\Build-DesktopLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -WindowClass 'ExampleWindowClass' `
  -WindowTitle 'Example' `
  -Arguments '--profile default' `
  -OutputPath '.\Example Desktop.exe'
```

Лаунчер активирует первое подходящее окно верхнего уровня или запускает настроенный EXE. `WindowClass` и `WindowTitle` необязательны; `-IncludeHiddenWindow` разрешает скрытые окна. Коды: `0` — успех, `1` — ошибка запуска, `2` — цель отсутствует, `3` — Windows отклонила перевод окна на передний план.

## Дополнение: tray action launcher

```powershell
.\Extras\Tray_EXE_Launcher\Build-TrayLauncher.ps1 `
  -TargetPath '%LOCALAPPDATA%\Example\Example.exe' `
  -ProcessName 'Example' `
  -TrayIconName 'Example' `
  -TrayMenuItemName 'Open' `
  -OutputPath '.\Example Tray.exe'
```

Если подходящего окна нет, лаунчер ищет иконку только в областях уведомлений Windows, открывает ее контекстное меню, вызывает ближайший подходящий пункт и возвращает указатель на прежнее место. Если нет ни окна, ни tray-иконки, запускается процесс. Код `4` означает ошибку tray-действия или последующей активации; коды `0`–`3` совпадают с desktop-режимом.

Desktop- и tray-лаунчеры поддерживают `--print-config`. Все сборщики принимают `-Force` для осознанной замены результата.

## Тесты и удаление

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LauncherBuilders.ps1
```

Тесты собирают все три варианта и проверяют встроенную конфигурацию и выбор действия. Они не автоматизируют реальное установленное Store-приложение или иконку в области уведомлений.

У созданных лаунчеров нет установщика и постоянного состояния. Для удаления достаточно удалить EXE.

## Диагностика

- Неоднозначный `-AppName` нужно заменить точным `-AppId`
- Код `3` обычно означает ограничение Windows на перевод фокуса, а не ошибку сборки
- Tray-имена зависят от accessibility-метаданных приложения и языка интерфейса; при постоянном коде `4` проверь фактические UI Automation имена
