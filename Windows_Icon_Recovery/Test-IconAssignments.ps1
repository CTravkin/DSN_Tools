[CmdletBinding()]
param([Parameter(Mandatory)][string]$ManifestPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IconRecovery.psm1') -Force

try {
    $result = Get-IconAudit -ManifestPath $ManifestPath
    $result | ConvertTo-Json -Depth 6
    if ($result.problems -eq 0) { exit 0 }
    exit 1
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
