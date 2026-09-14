# Windows Icon Recovery

[English](README.md) | [Русский](README.ru.md) | [DSN Tools](../README.ru.md)

Windows Icon Recovery сохраняет, проверяет, восстанавливает и откатывает `IconResource` папок и `IconLocation` ярлыков `.lnk` по версионированному JSON-манифесту.

Восстановление работает в fail-closed режиме: все цели и файлы с иконками проверяются до первой записи. Отсутствующие назначения и неверные атрибуты Explorer можно исправить; другая непустая иконка считается конфликтом, и тогда ничего не меняется. Перед восстановлением сохраняются все затрагиваемые файлы и их атрибуты.

## Требования

- Windows 10 или 11 и Windows PowerShell 5.1
- Права на изменение целевых папок, `desktop.ini`, `.lnk` и их атрибутов
- Абсолютные пути после раскрытия переменных окружения
- Доступная для записи директория резервных копий

Утилита проверяет существование файла с иконкой, но не проверяет наличие указанного resource index внутри EXE или DLL.

## Манифест

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

Манифест должен содержать хотя бы одну уникальную цель. Переменные окружения можно сохранить для переносимости. Обычно манифест содержит пути конкретной машины; проверь его перед коммитом или передачей. Пример: [`examples/icon-manifest.example.json`](examples/icon-manifest.example.json).

## Сохранение и проверка

```powershell
.\Export-IconManifest.ps1 `
  -OutputPath .\icons.json `
  -Folder '%USERPROFILE%\Example' `
  -Shortcut '%USERPROFILE%\Desktop\Example.lnk'

.\Test-IconAssignments.ps1 -ManifestPath .\icons.json
```

Проверка возвращает `0` при полном совпадении и `1` при любой проблеме или ошибке входных данных. Результат — JSON с деталями по целям.

## Восстановление и откат

Сначала просмотри план, затем примени его:

```powershell
.\Restore-IconAssignments.ps1 `
  -ManifestPath .\icons.json `
  -BackupRoot "$env:USERPROFILE\Icon Recovery Backups" `
  -WhatIf

.\Restore-IconAssignments.ps1 `
  -ManifestPath .\icons.json `
  -BackupRoot "$env:USERPROFILE\Icon Recovery Backups"
```

Восстановление возвращает `0` после успешной итоговой проверки, `2`, если preflight нашел конфликт, отсутствующую цель или источник иконки, и `1` при ошибке выполнения либо проверки. При ошибке в середине операции выполняется автоматический откат.

В возвращенной backup-директории лежат копии файлов, SHA-256 и исходные атрибуты файлов и папок. Явный откат:

```powershell
.\Undo-IconRecovery.ps1 -BackupPath 'C:\Path\To\Backup'
```

Восстановление и откат поддерживают `-WhatIf` и `-Confirm`. Explorer получает точечные уведомления об изменениях; утилита не очищает кеш иконок и не перезапускает Explorer.

## Тесты

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-IconRecovery.ps1
```

## Диагностика

- `IconConflict`: осознанно измени манифест или самостоятельно очисти назначение; утилита его не перезапишет
- `AttributeMismatch`: запусти восстановление, чтобы вернуть Hidden/System для `desktop.ini` и ReadOnly для папки
- Если видимая иконка не обновилась, сначала переоткрой папку: это может быть задержка кеша Explorer
