[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$BackupRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IconRecovery.psm1') -Force

try {
    $manifest = Import-IconRecoveryManifest -ManifestPath $ManifestPath
    $changes = [Collections.Generic.List[object]]::new()
    $conflicts = [Collections.Generic.List[object]]::new()
    $unrestorable = [Collections.Generic.List[object]]::new()

    foreach ($entry in $manifest.Entries) {
        $source = Get-IconSourceFile -Icon $entry.Icon
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $unrestorable.Add([pscustomobject]@{ type='IconSourceMissing'; path=$entry.Path; source=$source })
        }
        $state = if ($entry.Kind -eq 'folder') { Get-FolderIconState -Folder $entry.Path } else { Get-ShortcutIconState -Path $entry.Path }
        if (-not $state.Exists) {
            $unrestorable.Add([pscustomobject]@{ type=if($entry.Kind -eq 'folder'){'FolderMissing'}else{'ShortcutMissing'}; path=$entry.Path })
        }
        elseif (-not (Test-IconValueMissing -Icon $state.Icon) -and -not (Test-IconResourceEqual -Actual $state.Icon -Expected $entry.Icon)) {
            $conflicts.Add([pscustomobject]@{ type='IconConflict'; path=$entry.Path; expected=$entry.Icon; actual=$state.Icon })
        }
        else {
            $attributeMismatch = $entry.Kind -eq 'folder' -and (
                -not $state.FileExists -or
                -not ($state.FileAttributes -band [IO.FileAttributes]::Hidden) -or
                -not ($state.FileAttributes -band [IO.FileAttributes]::System) -or
                -not ($state.FolderAttributes -band [IO.FileAttributes]::ReadOnly)
            )
            if ((Test-IconValueMissing -Icon $state.Icon) -or $attributeMismatch) {
                $changes.Add([pscustomobject]@{ Entry=$entry; State=$state })
            }
        }
    }

    if ($conflicts.Count -gt 0 -or $unrestorable.Count -gt 0) {
        [pscustomobject]@{
            backup=$null; restored=0; planned=$changes.Count; conflicts=$conflicts.Count
            unrestorable=$unrestorable.Count; verified=$false
            conflictDetails=@($conflicts); unrestorableDetails=@($unrestorable)
        } | ConvertTo-Json -Depth 7
        exit 2
    }

    if ($changes.Count -gt 0 -and -not $PSCmdlet.ShouldProcess("$($changes.Count) icon assignment(s)", 'Restore')) {
        [pscustomobject]@{
            backup=$null; restored=0; planned=$changes.Count; conflicts=0
            unrestorable=0; verified=$false; whatIf=$true
        } | ConvertTo-Json -Depth 5
        exit 0
    }

    $backupPath = $null
    if ($changes.Count -gt 0) {
        $resolvedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
        New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
        $backupPath = Join-Path $resolvedBackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $filesPath = Join-Path $backupPath 'files'
        New-Item -ItemType Directory -Path $filesPath -Force | Out-Null
        $backupEntries = [Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($change in $changes) {
            $entry = $change.Entry
            $state = $change.State
            $sourceFile = if ($entry.Kind -eq 'folder') { $state.File } else { $entry.Path }
            $exists = Test-Path -LiteralPath $sourceFile -PathType Leaf
            $copyName = $null
            $sha = $null
            $sourceAttributes = $null
            if ($exists) {
                $sourceAttributes = [int](Get-Item -LiteralPath $sourceFile -Force).Attributes
                $index++
                $extension = [IO.Path]::GetExtension($sourceFile)
                $copyName = ('{0:D4}{1}' -f $index,$extension)
                $copyPath = Join-Path $filesPath $copyName
                Copy-Item -LiteralPath $sourceFile -Destination $copyPath
                $sha = (Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash
            }
            $targetAttributes = [int](Get-Item -LiteralPath $entry.Path -Force).Attributes
            $backupEntries.Add([ordered]@{
                kind=$entry.Kind; target=$entry.Path; targetAttributes=$targetAttributes
                sourceFile=$sourceFile; sourceFileAttributes=$sourceAttributes; existed=$exists
                backupFile=$copyName; sha256=$sha
            })
        }
        $backupDocument = [ordered]@{ version=1; createdAt=(Get-Date).ToString('o'); sourceManifest=$manifest.Path; entries=@($backupEntries) }
        [IO.File]::WriteAllText((Join-Path $backupPath 'manifest.json'), ($backupDocument | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

        $changedPaths = [Collections.Generic.List[string]]::new()
        try {
          foreach ($change in $changes) {
            $entry = $change.Entry
            $state = $change.State
            if ($entry.Kind -eq 'folder') {
                $content = if ($state.FileExists) { $state.Content } else { [pscustomobject]@{ Text=''; Encoding=[Text.UnicodeEncoding]::new($false,$true); HasBom=$true } }
                $updated = Set-IconResourceValue -Text $content.Text -Icon $entry.Icon
                Write-IconTextFile -Path $state.File -Text $updated -Encoding $content.Encoding -HasBom $content.HasBom
                $desktopItem = Get-Item -LiteralPath $state.File -Force
                $desktopItem.Attributes = $desktopItem.Attributes -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
                $folderItem = Get-Item -LiteralPath $entry.Path -Force
                $folderItem.Attributes = $folderItem.Attributes -bor [IO.FileAttributes]::ReadOnly
            }
            else {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($entry.Path)
                $shortcut.IconLocation = $entry.Icon
                $shortcut.Save()
            }
              $changedPaths.Add($entry.Path)
          }
          Send-IconItemRefresh -Path @($changedPaths)
        }
        catch {
            [void](Restore-IconRecoveryBackup -BackupPath $backupPath)
            throw "Icon restore failed and was rolled back: $($_.Exception.Message)"
        }
    }

    $verification = Get-IconAudit -ManifestPath $manifest.Path
    $result = [pscustomobject]@{
        backup=$backupPath
        restored=$changes.Count
        conflicts=$conflicts.Count
        unrestorable=$unrestorable.Count
        verified=($verification.problems -eq 0)
        conflictDetails=@($conflicts)
        unrestorableDetails=@($unrestorable)
        verificationDetails=@($verification.details)
    }
    $result | ConvertTo-Json -Depth 7
    if ($conflicts.Count -gt 0 -or $unrestorable.Count -gt 0) { exit 2 }
    if (-not $result.verified) { exit 1 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
