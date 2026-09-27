[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [ValidateSet('Strict', 'BestEffort')][string]$ApplyMode = 'Strict',
    [string]$BackupRoot,
    [switch]$IgnoreMachineBinding,
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

function Test-Property {
    param([AllowNull()]$Object, [string]$Name)
    $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-Property {
    param([AllowNull()]$Object, [string]$Name)
    if (-not (Test-Property -Object $Object -Name $Name)) { return $null }
    $Object.PSObject.Properties[$Name].Value
}

function Write-ApplyResult {
    param([Parameter(Mandatory)]$Result, [int]$ExitCode)
    $text = $Result | ConvertTo-Json -Depth 10 -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $text, [Text.UTF8Encoding]::new($false))
    }
    else {
        if ($Json) { Write-Output $text }
        elseif ($Result.verified) { Write-Output "Audio profile applied and verified. Backup: $($Result.backup)" }
        else { Write-Output "Audio profile completed with $(@($Result.errors).Count) error(s). Backup: $($Result.backup)" }
    }
    exit $ExitCode
}

function Invoke-ElevatedApply {
    $temporaryResult = Join-Path ([IO.Path]::GetTempPath()) ('WindowsAudioProfile-' + [guid]::NewGuid().ToString('N') + '.json')
    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $command = "& $(& $quote $PSCommandPath) -ProfilePath $(& $quote ([IO.Path]::GetFullPath($ProfilePath))) -ApplyMode $ApplyMode -BackupRoot $(& $quote ([IO.Path]::GetFullPath($BackupRoot))) -InternalElevated -ResultPath $(& $quote $temporaryResult) -Confirm:`$false"
    if ($IgnoreMachineBinding) { $command += ' -IgnoreMachineBinding' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $process = Start-Process -FilePath $powerShell -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru
        if (-not (Test-Path -LiteralPath $temporaryResult -PathType Leaf)) { throw "Elevated Apply exited with code $($process.ExitCode) without a result." }
        $result = Get-Content -Raw -LiteralPath $temporaryResult | ConvertFrom-Json
        if ($Json) { $result | ConvertTo-Json -Depth 10 -Compress }
        elseif ($result.verified) { Write-Output "Audio profile applied and verified. Backup: $($result.backup)" }
        else { Write-Output "Audio profile failed: $($result.error)" }
        exit $process.ExitCode
    }
    finally { Remove-Item -LiteralPath $temporaryResult -Force -ErrorAction SilentlyContinue }
}

$backupPath = $null
$errors = [Collections.Generic.List[object]]::new()
$rolledBack = $false

try {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $PSScriptRoot 'Backups' }
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    $profile = Import-AudioProfile -Path $ProfilePath
    $inventory = @(Get-WindowsAudioInventory)
    $validation = Test-AudioProfileState -Profile $profile -Inventory $inventory -IgnoreMachineBinding:$IgnoreMachineBinding
    if (-not $validation.valid) { throw (@($validation.errors | ForEach-Object { $_.message }) -join '; ') }
    $resolved = Resolve-AudioProfileDevices -Profile $profile -Inventory $inventory
    $priorities = @(Get-AudioPriorityAssignments -Profile $profile -ResolvedDevices $resolved -Inventory $inventory)
    $matchedCount = @($resolved.Values | Where-Object { $null -ne $_ }).Count
    $initialDifferences = @(Get-AudioProfileDifferences -Profile $profile -ResolvedDevices $resolved -Inventory $inventory)

    if ($WhatIfPreference) {
        [pscustomobject][ordered]@{
            applied = $false; whatIf = $true; mode = $ApplyMode; devices = $matchedCount
            differences = $initialDifferences.Count; priorityAssignments = $priorities.Count
            warnings = @($validation.warnings); backup = $null
        } | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }
    if ($initialDifferences.Count -eq 0) {
        Write-ApplyResult -Result ([pscustomobject][ordered]@{
            applied=$false; verified=$true; mode=$ApplyMode; devices=$matchedCount; changes=0
            backup=$null; warnings=@($validation.warnings); errors=@()
        }) -ExitCode 0
    }
    if (-not (Test-Administrator)) {
        if ($InternalElevated) { throw 'Internal elevated Apply does not have an administrator token.' }
        Invoke-ElevatedApply
    }

    $resolvedBackupRoot = [IO.Path]::GetFullPath($BackupRoot)
    New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
    $backupPath = Join-Path $resolvedBackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $backupPath | Out-Null
    $backupFile = Join-Path $backupPath 'state.json'
    $backup = New-AudioBackupDocument -Profile $profile -ResolvedDevices $resolved -Inventory $inventory
    [IO.File]::WriteAllText($backupFile, ($backup | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    foreach ($profileDevice in @($profile.devices)) {
        $key = [string]$profileDevice.key
        $endpoint = $resolved[$key]
        if ($null -eq $endpoint) { continue }
        $settings = Get-Property -Object $profileDevice -Name 'settings'
        if ($null -eq $settings) { continue }
        $backupDevice = @($backup.devices | Where-Object { $_.key -eq $key })[0]
        $temporarilyEnabled = $false
        try {
            $volume = Get-Property -Object $settings -Name 'volume'
            if ($null -ne $volume -and -not $endpoint.Active) {
                Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible $true
                $temporarilyEnabled = $true
                Start-Sleep -Milliseconds 500
                $endpoint = @(Get-WindowsAudioInventory | Where-Object { $_.Flow -eq $endpoint.Flow -and $_.EndpointId -eq $endpoint.EndpointId })[0]
                if (-not $endpoint.Active) { throw "Device '$key' could not be activated for volume configuration." }
                if ($null -eq $backupDevice.volume) {
                    $backupDevice.volume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                    [IO.File]::WriteAllText($backupFile, ($backup | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
                }
            }

            $propertyArguments = @{ Endpoint=$endpoint }
            foreach ($property in @('format', 'name', 'icon')) {
                if (Test-Property -Object $settings -Name $property) {
                    $parameterName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
                    $propertyArguments[$parameterName] = Get-Property -Object $settings -Name $property
                }
            }
            if ($propertyArguments.Count -gt 1) { Set-WindowsAudioEndpointProperties @propertyArguments }

            if ($null -ne $volume) {
                $volumeArguments = @{ Endpoint=$endpoint }
                foreach ($property in @('percent', 'decibels', 'muted')) {
                    if (Test-Property -Object $volume -Name $property) {
                        $parameterName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
                        $volumeArguments[$parameterName] = Get-Property -Object $volume -Name $property
                    }
                }
                Set-WindowsAudioEndpointVolume @volumeArguments
                $actualVolume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                if ((Test-Property -Object $volume -Name 'percent') -and [Math]::Abs([double]$volume.percent - [double]$actualVolume.percent) -gt 0.11) { throw "Volume verification failed for '$key'." }
                if ((Test-Property -Object $volume -Name 'decibels') -and [Math]::Abs([double]$volume.decibels - [double]$actualVolume.decibels) -gt 0.11) { throw "Volume verification failed for '$key'." }
                if ((Test-Property -Object $volume -Name 'muted') -and [bool]$volume.muted -ne [bool]$actualVolume.muted) { throw "Mute verification failed for '$key'." }
            }
            if ((Test-Property -Object $settings -Name 'enabled') -or $temporarilyEnabled) {
                $desiredEnabled = if (Test-Property -Object $settings -Name 'enabled') { [bool]$settings.enabled } else { [bool]$backupDevice.enabled }
                Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible $desiredEnabled
            }
        }
        catch {
            if ($temporarilyEnabled) { Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible ([bool]$backupDevice.enabled) -ErrorAction SilentlyContinue }
            $errors.Add([pscustomobject]@{ device=$key; error=$_.Exception.Message })
            if ($ApplyMode -eq 'Strict') { throw }
        }
    }

    if ($priorities.Count -gt 0) {
        $currentInventory = @(Get-WindowsAudioInventory)
        foreach ($flow in @('render', 'capture')) {
            foreach ($role in @('console', 'multimedia', 'communications')) {
                $ordered = @($priorities | Where-Object { $_.Flow -eq $flow -and $_.Role -eq $role } | Sort-Object Level -Descending)
                foreach ($assignment in $ordered) {
                    $candidate = @($currentInventory | Where-Object { $_.Flow -eq $flow -and $_.EndpointId -eq $assignment.EndpointId })[0]
                    if ($candidate.Active) { Set-WindowsAudioDefaultEndpoint -EndpointId $candidate.FullEndpointId -Role $role; break }
                }
            }
        }
        $priorityPlan = [ordered]@{
            version=1; machineIdSha256=(Get-AudioMachineHash)
            assignments=@($priorities | ForEach-Object { [ordered]@{ flow=$_.Flow; endpointId=$_.EndpointId; roleIndex=$_.RoleIndex; hasValue=$true; level=$_.Level } })
        }
        $priorityPlanPath = Join-Path $backupPath 'priority-plan.json'
        [IO.File]::WriteAllText($priorityPlanPath, ($priorityPlan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        & (Join-Path $PSScriptRoot 'Set-AudioPriority.ps1') -Mode Controller -PlanPath $priorityPlanPath -Json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Priority worker exited with code $LASTEXITCODE." }
    }

    $postInventory = @(Get-WindowsAudioInventory)
    $differences = @(Get-AudioProfileDifferences -Profile $profile -ResolvedDevices $resolved -Inventory $postInventory)
    foreach ($difference in $differences) { $errors.Add([pscustomobject]@{ device=$difference.device; error="Verification failed for $($difference.property)." }) }
    if ($differences.Count -gt 0 -and $ApplyMode -eq 'Strict') { throw "Post-apply verification found $($differences.Count) difference(s)." }
    $verified = $errors.Count -eq 0
    Write-ApplyResult -Result ([pscustomobject][ordered]@{
        applied=$true; verified=$verified; mode=$ApplyMode; devices=$matchedCount
        changes=$initialDifferences.Count; backup=$backupPath; warnings=@($validation.warnings); errors=@($errors)
    }) -ExitCode $(if ($verified) { 0 } else { 2 })
}
catch {
    $failure = $_.Exception.Message
    if ($ApplyMode -eq 'Strict' -and $null -ne $backupPath -and (Test-Path -LiteralPath (Join-Path $backupPath 'state.json'))) {
        try {
            & (Join-Path $PSScriptRoot 'Undo-AudioProfile.ps1') -BackupPath $backupPath -InternalElevated -Json -Confirm:$false | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Undo exited with code $LASTEXITCODE." }
            $rolledBack = $true
        }
        catch { $errors.Add([pscustomobject]@{ device=$null; error="Rollback failed: $($_.Exception.Message)" }) }
    }
    $result = [pscustomobject][ordered]@{
        applied=$false; verified=$false; mode=$ApplyMode; backup=$backupPath
        rolledBack=$rolledBack; error=$failure; errors=@($errors)
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), ($result | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
    }
    elseif ($Json) { $result | ConvertTo-Json -Depth 10 -Compress }
    else { [Console]::Error.WriteLine($failure) }
    exit 1
}
