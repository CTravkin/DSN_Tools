$ErrorActionPreference = 'Stop'

$utilityRoot = Split-Path -Parent $PSScriptRoot
$exportScript = Join-Path $utilityRoot 'Export-IconManifest.ps1'
$auditScript = Join-Path $utilityRoot 'Test-IconAssignments.ps1'
$restoreScript = Join-Path $utilityRoot 'Restore-IconAssignments.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('IconRecovery-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-JsonScript {
    param([string]$Script, [string[]]$Arguments)

    $stderr = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.err')
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2> $stderr
    $exitCode = $LASTEXITCODE
    $errorOutput = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
    $outputText = if ($null -eq $output) { '' } else { [string](@($output) -join "`n") }
    $errorText = if ($null -eq $errorOutput) { '' } else { [string]$errorOutput }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $outputText.Trim(); Error = $errorText.Trim() }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $env:ICON_RECOVERY_TEST_ROOT = $testRoot
    $folder = Join-Path $testRoot 'Folder'
    New-Item -ItemType Directory -Path $folder | Out-Null
    $iconFile = Join-Path $testRoot 'sample.ico'
    [System.IO.File]::WriteAllBytes($iconFile, [byte[]](0, 0, 1, 0))
    $iconResource = '%ICON_RECOVERY_TEST_ROOT%\sample.ico,0'
    $desktopIni = Join-Path $folder 'desktop.ini'
    [System.IO.File]::WriteAllText($desktopIni, "[.ShellClassInfo]`r`nIconResource=$iconResource`r`nInfoTip=keep-this`r`n", [System.Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $desktopIni -Force).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    (Get-Item -LiteralPath $folder -Force).Attributes = (Get-Item -LiteralPath $folder -Force).Attributes -bor [System.IO.FileAttributes]::ReadOnly

    $target = Join-Path $testRoot 'target.txt'
    Set-Content -LiteralPath $target -Value 'target'
    $shortcut = Join-Path $testRoot 'Example.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $target
    $link.Arguments = '--keep'
    $link.IconLocation = $iconResource
    $link.Save()

    $manifest = Join-Path $testRoot 'icons.json'
    $export = Invoke-JsonScript -Script $exportScript -Arguments @('-OutputPath', $manifest, '-Folder', '%ICON_RECOVERY_TEST_ROOT%\Folder', '-Shortcut', '%ICON_RECOVERY_TEST_ROOT%\Example.lnk')
    Assert-True ($export.ExitCode -eq 0) "Export failed: $($export.Error)"
    $captured = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
    Assert-True ($captured.version -eq 1) 'Exported manifest version must be 1'
    Assert-True ($captured.folders[0].path -eq '%ICON_RECOVERY_TEST_ROOT%\Folder') 'Export must preserve portable folder path'
    Assert-True ($captured.shortcuts[0].icon -eq $iconResource) 'Export must capture shortcut icon'

    $cleanAudit = Invoke-JsonScript -Script $auditScript -Arguments @('-ManifestPath', $manifest)
    Assert-True ($cleanAudit.ExitCode -eq 0) "Clean audit failed: $($cleanAudit.Output) $($cleanAudit.Error)"
    Assert-True ((ConvertFrom-Json $cleanAudit.Output).problems -eq 0) 'Clean audit must report zero problems'

    (Get-Item -LiteralPath $desktopIni -Force).Attributes = [System.IO.FileAttributes]::Normal
    [System.IO.File]::WriteAllText($desktopIni, "[.ShellClassInfo]`r`nInfoTip=keep-this`r`n", [System.Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $desktopIni -Force).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    Remove-Item -LiteralPath $shortcut -Force
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $target
    $link.Arguments = '--keep'
    $link.Save()

    $brokenAudit = Invoke-JsonScript -Script $auditScript -Arguments @('-ManifestPath', $manifest)
    Assert-True ($brokenAudit.ExitCode -eq 1) 'Missing assignments must make audit fail'
    Assert-True ((ConvertFrom-Json $brokenAudit.Output).problems -eq 2) 'Audit must report both missing assignments'

    $backupRoot = Join-Path $testRoot 'Backups'
    $restore = Invoke-JsonScript -Script $restoreScript -Arguments @('-ManifestPath', $manifest, '-BackupRoot', $backupRoot)
    Assert-True ($restore.ExitCode -eq 0) "Restore failed: $($restore.Output) $($restore.Error)"
    $restoreResult = ConvertFrom-Json $restore.Output
    Assert-True ($restoreResult.restored -eq 2) 'Restore must repair folder and shortcut icons'
    Assert-True (Test-Path -LiteralPath (Join-Path $restoreResult.backup 'manifest.json')) 'Restore must create a backup manifest'
    $desktopText = [System.IO.File]::ReadAllText($desktopIni)
    Assert-True ($desktopText -match [regex]::Escape("IconResource=$iconResource")) 'Folder icon was not restored'
    Assert-True ($desktopText -match 'InfoTip=keep-this') 'Unrelated desktop.ini content must be preserved'
    $link = $shell.CreateShortcut($shortcut)
    Assert-True ($link.IconLocation -eq $iconResource) 'Shortcut icon was not restored'
    Assert-True ($link.TargetPath -eq $target) 'Shortcut target must be preserved'
    Assert-True ($link.Arguments -eq '--keep') 'Shortcut arguments must be preserved'

    (Get-Item -LiteralPath $desktopIni -Force).Attributes = [System.IO.FileAttributes]::Normal
    [System.IO.File]::WriteAllText($desktopIni, "[.ShellClassInfo]`r`nIconResource=%SystemRoot%\system32\shell32.dll,4`r`n", [System.Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $desktopIni -Force).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    $conflict = Invoke-JsonScript -Script $restoreScript -Arguments @('-ManifestPath', $manifest, '-BackupRoot', $backupRoot)
    Assert-True ($conflict.ExitCode -eq 2) 'A non-empty conflicting icon must not be overwritten'
    Assert-True ([System.IO.File]::ReadAllText($desktopIni) -match 'shell32\.dll,4') 'Conflicting icon was overwritten'

    Write-Output 'PASS: Windows icon export, audit, backup, restore, and conflict handling'
}
finally {
    Remove-Item Env:ICON_RECOVERY_TEST_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
