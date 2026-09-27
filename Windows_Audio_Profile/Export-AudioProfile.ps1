[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Name = 'Windows audio profile',
    [switch]$Force,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    $fullPath = [IO.Path]::GetFullPath($OutputPath)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) { throw "Output file already exists; use -Force to replace it: $fullPath" }
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $inventory = @(Get-WindowsAudioInventory)
    if ($inventory.Count -eq 0) { throw 'No Windows audio endpoints were found.' }
    $document = New-AudioProfileDocument -Inventory $inventory -Name $Name
    [IO.File]::WriteAllText($fullPath, ($document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $result = [pscustomobject]@{ exported=$true; path=$fullPath; devices=$inventory.Count }
    if ($Json) { $result | ConvertTo-Json -Depth 4 -Compress }
    else { Write-Output "Exported $($inventory.Count) audio endpoints to $fullPath" }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
