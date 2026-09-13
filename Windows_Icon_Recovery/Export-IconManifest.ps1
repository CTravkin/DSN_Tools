[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string[]]$Folder = @(),
    [string[]]$Shortcut = @()
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IconRecovery.psm1') -Force

try {
    if ($Folder.Count -eq 0 -and $Shortcut.Count -eq 0) { throw 'Specify at least one -Folder or -Shortcut' }
    $folders = foreach ($portable in $Folder) {
        $path = Resolve-IconPortablePath -Path $portable
        $state = Get-FolderIconState -Folder $path
        if (-not $state.Exists) { throw "Folder does not exist: $path" }
        if (-not $state.FileExists -or (Test-IconValueMissing -Icon $state.Icon)) { throw "Folder has no IconResource: $path" }
        [ordered]@{ path=$portable; icon=$state.Icon }
    }
    $shortcuts = foreach ($portable in $Shortcut) {
        $path = Resolve-IconPortablePath -Path $portable
        $state = Get-ShortcutIconState -Path $path
        if (-not $state.Exists) { throw "Shortcut does not exist: $path" }
        if (Test-IconValueMissing -Icon $state.Icon) { throw "Shortcut has no IconLocation: $path" }
        [ordered]@{ path=$portable; icon=$state.Icon }
    }
    $document = [ordered]@{ version=1; folders=@($folders); shortcuts=@($shortcuts) }
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($resolvedOutput, ($document | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [void](Import-IconRecoveryManifest -ManifestPath $resolvedOutput)
    [pscustomobject]@{ manifest=$resolvedOutput; folders=@($folders).Count; shortcuts=@($shortcuts).Count } | ConvertTo-Json -Depth 3
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
