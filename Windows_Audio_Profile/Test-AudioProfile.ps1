[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [switch]$IgnoreMachineBinding,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    $profile = Import-AudioProfile -Path $ProfilePath
    $inventory = @(Get-WindowsAudioInventory)
    $result = Test-AudioProfileState -Profile $profile -Inventory $inventory -IgnoreMachineBinding:$IgnoreMachineBinding
    if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress }
    elseif ($result.valid) { Write-Output "Profile is valid: $($result.matchedDevices) device(s) matched, $(@($result.warnings).Count) warning(s)." }
    else { Write-Output "Profile is invalid: $(@($result.errors).Count) error(s)." }
    if ($result.valid) { exit 0 }
    exit 1
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
