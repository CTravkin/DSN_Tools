[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$Json,
    [switch]$InternalElevated,
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedUndo {
    $temporaryResult = Join-Path ([IO.Path]::GetTempPath()) ('WindowsAudioProfile-Undo-' + [guid]::NewGuid().ToString('N') + '.json')
    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $command = "& $(& $quote $PSCommandPath) -BackupPath $(& $quote ([IO.Path]::GetFullPath($BackupPath))) -InternalElevated -ResultPath $(& $quote $temporaryResult) -Confirm:`$false"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $process = Start-Process -FilePath $powerShell -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru
        if (-not (Test-Path -LiteralPath $temporaryResult -PathType Leaf)) { throw "Elevated Undo exited with code $($process.ExitCode) without a result." }
        $result = Get-Content -Raw -LiteralPath $temporaryResult | ConvertFrom-Json
        if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress }
        elseif ($result.restored) { Write-Output "Audio state restored from $BackupPath" }
        else { Write-Output "Audio state restore failed: $($result.error)" }
        exit $process.ExitCode
    }
    finally { Remove-Item -LiteralPath $temporaryResult -Force -ErrorAction SilentlyContinue }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    $resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
    $backupFile = if (Test-Path -LiteralPath $resolvedBackup -PathType Container) { Join-Path $resolvedBackup 'state.json' } else { $resolvedBackup }
    $backup = [IO.File]::ReadAllText($backupFile, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    if ([int]$backup.version -ne 1) { throw 'Unsupported audio backup version; expected 1.' }
    if (-not [string]::Equals([string]$backup.machineIdSha256, (Get-AudioMachineHash), [StringComparison]::OrdinalIgnoreCase)) { throw 'Audio backup belongs to another Windows installation.' }
    if ($WhatIfPreference) {
        [pscustomobject]@{ restored=$false; whatIf=$true; backup=$resolvedBackup; devices=@($backup.devices).Count } | ConvertTo-Json -Compress
        exit 0
    }
    if (-not (Test-Administrator)) {
        if ($InternalElevated) { throw 'Internal elevated Undo does not have an administrator token.' }
        Invoke-ElevatedUndo
    }

    $inventory = @(Get-WindowsAudioInventory)
    foreach ($device in @($backup.devices)) {
        $endpoint = @($inventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
        if ($null -eq $endpoint) { throw "Backup endpoint is no longer registered: $($device.flow)/$($device.endpointId)" }
        $touched = @($device.touched)
        $temporarilyEnabled = $false
        if ($touched -contains 'volume' -and $null -ne $device.volume -and -not $endpoint.Active) {
            Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible $true
            $temporarilyEnabled = $true
            Start-Sleep -Milliseconds 500
            $endpoint = @(Get-WindowsAudioInventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
            if (-not $endpoint.Active) { throw "Backup endpoint could not be activated: $($device.key)" }
        }
        $propertyArguments = @{ Endpoint=$endpoint }
        foreach ($property in @('format', 'name', 'icon')) {
            if ($touched -contains $property) {
                $parameterName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
                $propertyArguments[$parameterName] = $device.$property
            }
        }
        if ($propertyArguments.Count -gt 1) { Set-WindowsAudioEndpointProperties @propertyArguments }
        if ($touched -contains 'volume' -and $null -ne $device.volume) {
            Set-WindowsAudioEndpointVolume -Endpoint $endpoint -Decibels ([double]$device.volume.decibels) -Muted ([bool]$device.volume.muted)
        }
        if (($touched -contains 'enabled') -or $temporarilyEnabled) { Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible ([bool]$device.enabled) }
    }

    if ([bool]$backup.priorityIncluded) {
        foreach ($default in @($backup.defaults)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$default.endpointId)) { Set-WindowsAudioDefaultEndpoint -EndpointId ([string]$default.endpointId) -Role ([string]$default.role) }
        }
        $assignments = [Collections.Generic.List[object]]::new()
        foreach ($device in @($backup.devices)) {
            for ($roleIndex = 0; $roleIndex -lt 3; $roleIndex++) {
                $role = @('console', 'multimedia', 'communications')[$roleIndex]
                $level = $device.levels.PSObject.Properties[$role].Value
                $assignments.Add([ordered]@{ flow=$device.flow; endpointId=$device.endpointId; roleIndex=$roleIndex; hasValue=($null -ne $level); level=$level })
            }
        }
        $plan = [ordered]@{ version=1; machineIdSha256=(Get-AudioMachineHash); assignments=@($assignments) }
        $planPath = Join-Path $resolvedBackup 'undo-priority-plan.json'
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        & (Join-Path $PSScriptRoot 'Set-AudioPriority.ps1') -Mode Controller -PlanPath $planPath -Json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Priority restore worker exited with code $LASTEXITCODE." }
    }

    $result = [pscustomobject]@{ restored=$true; backup=$resolvedBackup; devices=@($backup.devices).Count }
    $text = $result | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $text, [Text.UTF8Encoding]::new($false)) }
    elseif ($Json) { Write-Output $text }
    else { Write-Output "Audio state restored from $resolvedBackup" }
    exit 0
}
catch {
    $result = [pscustomobject]@{ restored=$false; backup=$BackupPath; error=$_.Exception.Message }
    $text = $result | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $text, [Text.UTF8Encoding]::new($false)) }
    elseif ($Json) { Write-Output $text }
    else { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
