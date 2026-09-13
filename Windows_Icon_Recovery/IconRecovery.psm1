Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Resolve-IconPortablePath {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded) -or -not [IO.Path]::IsPathRooted($expanded)) {
        throw "Path must be absolute after environment expansion: $Path"
    }
    [IO.Path]::GetFullPath($expanded).TrimEnd('\')
}

function Get-IconSourceFile {
    param([Parameter(Mandatory)][string]$Icon)

    $expanded = [Environment]::ExpandEnvironmentVariables($Icon)
    $match = [regex]::Match($expanded, '^(?<path>.*),(?<index>-?\d+)$')
    $path = if ($match.Success) { $match.Groups['path'].Value } else { $expanded }
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
        throw "Icon source must be an absolute path after environment expansion: $Icon"
    }
    [IO.Path]::GetFullPath($path)
}

function Read-IconTextFile {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $false
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true)
        $offset = 2
        $hasBom = $true
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $true)
        $offset = 2
        $hasBom = $true
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true)
        $offset = 3
        $hasBom = $true
    }
    else {
        $offset = 0
        try {
            $encoding = [Text.UTF8Encoding]::new($false, $true)
            [void]$encoding.GetString($bytes)
        }
        catch {
            $encoding = [Text.Encoding]::GetEncoding(1251)
        }
    }

    [pscustomobject]@{
        Text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        Encoding = $encoding
        HasBom = $hasBom
    }
}

function Write-IconTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][Text.Encoding]$Encoding,
        [Parameter(Mandatory)][bool]$HasBom
    )

    if ($Encoding.CodePage -eq 65001) {
        $writerEncoding = [Text.UTF8Encoding]::new($HasBom)
    }
    elseif ($Encoding.CodePage -eq 1200) {
        $writerEncoding = [Text.UnicodeEncoding]::new($false, $HasBom)
    }
    elseif ($Encoding.CodePage -eq 1201) {
        $writerEncoding = [Text.UnicodeEncoding]::new($true, $HasBom)
    }
    else {
        $writerEncoding = $Encoding
    }
    $existed = Test-Path -LiteralPath $Path -PathType Leaf
    $originalAttributes = if ($existed) { (Get-Item -LiteralPath $Path -Force).Attributes } else { [IO.FileAttributes]::Normal }
    if ($existed) {
        $blocking = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        (Get-Item -LiteralPath $Path -Force).Attributes = $originalAttributes -band (-bnot $blocking)
    }
    try {
        [IO.File]::WriteAllText($Path, $Text, $writerEncoding)
    }
    finally {
        if ($existed -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            (Get-Item -LiteralPath $Path -Force).Attributes = $originalAttributes
        }
    }
}

function Get-IconResourceValue {
    param([AllowEmptyString()][string]$Text)

    $match = [regex]::Match($Text, '(?im)^IconResource=(?<value>.+?)\s*$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    $null
}

function Test-IconValueMissing {
    param([AllowNull()][AllowEmptyString()][string]$Icon)
    [string]::IsNullOrWhiteSpace($Icon) -or $Icon.Trim() -eq ',0'
}

function Set-IconResourceValue {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Icon)

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $match = [regex]::Match($Text, '(?im)^IconResource=.*?\s*$')
    if ($match.Success) {
        return $Text.Remove($match.Index, $match.Length).Insert($match.Index, "IconResource=$Icon")
    }
    $section = [regex]::Match($Text, '(?im)^\[\.ShellClassInfo\]\s*$')
    if ($section.Success) {
        return $Text.Insert($section.Index + $section.Length, $newline + "IconResource=$Icon")
    }
    "[.ShellClassInfo]${newline}IconResource=$Icon${newline}${newline}$Text"
}

function Import-IconRecoveryManifest {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $resolved = (Resolve-Path -LiteralPath $ManifestPath).Path
    $document = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    if ($null -eq $document.version -or [int]$document.version -ne 1) {
        throw 'Unsupported icon manifest version; expected version 1'
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($group in @(@('folder', @($document.folders)), @('shortcut', @($document.shortcuts)))) {
        foreach ($item in $group[1]) {
            if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.path) -or [string]::IsNullOrWhiteSpace([string]$item.icon)) {
                throw "Every $($group[0]) entry requires non-empty path and icon values"
            }
            $resolvedPath = Resolve-IconPortablePath -Path ([string]$item.path)
            [void](Get-IconSourceFile -Icon ([string]$item.icon))
            if (-not $seen.Add($resolvedPath)) { throw "Duplicate icon target: $resolvedPath" }
            $entries.Add([pscustomobject]@{
                Kind = $group[0]
                PortablePath = [string]$item.path
                Path = $resolvedPath
                Icon = [string]$item.icon
            })
        }
    }
    [pscustomobject]@{ Path = $resolved; Entries = @($entries) }
}

function Get-FolderIconState {
    param([Parameter(Mandatory)][string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return [pscustomobject]@{ Exists=$false; FileExists=$false; Icon=$null; File=$null; FolderAttributes=$null; FileAttributes=$null }
    }
    $desktopIni = Join-Path $Folder 'desktop.ini'
    if (-not (Test-Path -LiteralPath $desktopIni -PathType Leaf)) {
        return [pscustomobject]@{ Exists=$true; FileExists=$false; Icon=$null; File=$desktopIni; FolderAttributes=(Get-Item -LiteralPath $Folder -Force).Attributes; FileAttributes=$null }
    }
    $content = Read-IconTextFile -Path $desktopIni
    [pscustomobject]@{
        Exists = $true
        FileExists = $true
        Icon = Get-IconResourceValue -Text $content.Text
        File = $desktopIni
        FolderAttributes = (Get-Item -LiteralPath $Folder -Force).Attributes
        FileAttributes = (Get-Item -LiteralPath $desktopIni -Force).Attributes
        Content = $content
    }
}

function Get-ShortcutIconState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists=$false; Icon=$null; File=$Path }
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    [pscustomobject]@{
        Exists = $true
        Icon = $shortcut.IconLocation
        File = $Path
        TargetPath = $shortcut.TargetPath
        Arguments = $shortcut.Arguments
        WorkingDirectory = $shortcut.WorkingDirectory
    }
}

function Get-IconAudit {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $manifest = Import-IconRecoveryManifest -ManifestPath $ManifestPath
    $details = [Collections.Generic.List[object]]::new()
    $folderCount = 0
    $shortcutCount = 0
    foreach ($entry in $manifest.Entries) {
        if ($entry.Kind -eq 'folder') {
            $folderCount++
            $state = Get-FolderIconState -Folder $entry.Path
            if (-not $state.Exists) { $details.Add([pscustomobject]@{ type='FolderMissing'; path=$entry.Path; expected=$entry.Icon; actual=$null }); continue }
            if (-not $state.FileExists) { $details.Add([pscustomobject]@{ type='DesktopIniMissing'; path=$entry.Path; expected=$entry.Icon; actual=$null }); continue }
            if (Test-IconValueMissing -Icon $state.Icon) { $details.Add([pscustomobject]@{ type='IconMissing'; path=$entry.Path; expected=$entry.Icon; actual=$state.Icon }) }
            elseif (-not [string]::Equals($state.Icon, $entry.Icon, [StringComparison]::OrdinalIgnoreCase)) { $details.Add([pscustomobject]@{ type='IconConflict'; path=$entry.Path; expected=$entry.Icon; actual=$state.Icon }) }
            if (-not ($state.FileAttributes -band [IO.FileAttributes]::Hidden) -or -not ($state.FileAttributes -band [IO.FileAttributes]::System) -or -not ($state.FolderAttributes -band [IO.FileAttributes]::ReadOnly)) {
                $details.Add([pscustomobject]@{ type='AttributeMismatch'; path=$entry.Path; expected='desktop.ini Hidden+System; folder ReadOnly'; actual="$($state.FileAttributes); $($state.FolderAttributes)" })
            }
        }
        else {
            $shortcutCount++
            $state = Get-ShortcutIconState -Path $entry.Path
            if (-not $state.Exists) { $details.Add([pscustomobject]@{ type='ShortcutMissing'; path=$entry.Path; expected=$entry.Icon; actual=$null }); continue }
            if (Test-IconValueMissing -Icon $state.Icon) { $details.Add([pscustomobject]@{ type='IconMissing'; path=$entry.Path; expected=$entry.Icon; actual=$state.Icon }) }
            elseif (-not [string]::Equals($state.Icon, $entry.Icon, [StringComparison]::OrdinalIgnoreCase)) { $details.Add([pscustomobject]@{ type='IconConflict'; path=$entry.Path; expected=$entry.Icon; actual=$state.Icon }) }
        }
        $source = Get-IconSourceFile -Icon $entry.Icon
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $details.Add([pscustomobject]@{ type='IconSourceMissing'; path=$entry.Path; expected=$source; actual=$null }) }
    }
    [pscustomobject]@{
        manifest = $manifest.Path
        folders = $folderCount
        shortcuts = $shortcutCount
        problems = $details.Count
        details = @($details)
    }
}

function Send-IconItemRefresh {
    param([Parameter(Mandatory)][string[]]$Path)

    if (-not ('DSNTools.IconRefresh' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DSNTools {
    public static class IconRefresh {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern void SHChangeNotify(uint eventId, uint flags, string item, IntPtr item2);
    }
}
'@
    }
    foreach ($item in $Path) { [DSNTools.IconRefresh]::SHChangeNotify(0x00002000, 0x0005, $item, [IntPtr]::Zero) }
}

Export-ModuleMember -Function Resolve-IconPortablePath,Get-IconSourceFile,Read-IconTextFile,Write-IconTextFile,Get-IconResourceValue,Test-IconValueMissing,Set-IconResourceValue,Import-IconRecoveryManifest,Get-FolderIconState,Get-ShortcutIconState,Get-IconAudit,Send-IconItemRefresh
