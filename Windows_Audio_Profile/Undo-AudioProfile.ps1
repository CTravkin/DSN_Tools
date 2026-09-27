[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [switch]$WhatIf,
    [switch]$Json,
    [switch]$InternalElevated,
    [string]$ResultPath,
    [string]$ExpectedBackupSha256
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
    $command = "& $(& $quote $PSCommandPath) -BackupPath $(& $quote ([IO.Path]::GetFullPath($BackupPath))) -InternalElevated -ResultPath $(& $quote $temporaryResult) -ExpectedBackupSha256 $(& $quote $backupSha256)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $process = Start-Process -FilePath $powerShell -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru
        if (-not (Test-Path -LiteralPath $temporaryResult -PathType Leaf)) { throw "Elevated Undo exited with code $($process.ExitCode) without a result." }
        $result = Get-Content -Raw -LiteralPath $temporaryResult | ConvertFrom-Json
        if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress }
        elseif ($result.restored) { Write-Output "Audio state restored from $BackupPath" }
        else {
            $messages = if ($result.PSObject.Properties['errors']) { @($result.errors | ForEach-Object { $_.error }) } else { @() }
            if ($messages.Count -eq 0 -and $result.PSObject.Properties['error']) { $messages = @([string]$result.error) }
            Write-Output "Audio state restore failed: $($messages -join '; ')"
        }
        exit $process.ExitCode
    }
    finally { Remove-Item -LiteralPath $temporaryResult -Force -ErrorAction SilentlyContinue }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    $resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
    $backupFile = if (Test-Path -LiteralPath $resolvedBackup -PathType Container) { Join-Path $resolvedBackup 'state.json' } else { $resolvedBackup }
    if ($InternalElevated -and [string]::IsNullOrWhiteSpace($ExpectedBackupSha256)) { throw 'Internal elevated Undo requires an expected backup hash.' }
    $backupSha256 = if ([string]::IsNullOrWhiteSpace($ExpectedBackupSha256)) { (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash } else { $ExpectedBackupSha256 }
    $backup = Import-AudioBackup -Path $backupFile -ExpectedSha256 $backupSha256
    if (-not [string]::Equals([string]$backup.machineIdSha256, (Get-AudioMachineHash), [StringComparison]::OrdinalIgnoreCase)) { throw 'Audio backup belongs to another Windows installation.' }
    if ($WhatIf) {
        [pscustomobject]@{ restored=$false; whatIf=$true; backup=$resolvedBackup; devices=@($backup.devices).Count } | ConvertTo-Json -Compress
        exit 0
    }
    if (-not (Test-Administrator)) {
        if ($InternalElevated) { throw 'Internal elevated Undo does not have an administrator token.' }
        Invoke-ElevatedUndo
    }

    $backupDirectory = Split-Path -Parent $backupFile
    $errors = [Collections.Generic.List[object]]::new()
    $verifiedVolumeKeys = [Collections.Generic.List[string]]::new()
    $inventory = @(Get-WindowsAudioInventory)
    foreach ($device in @($backup.devices)) {
        $endpoint = @($inventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
        if ($null -eq $endpoint) {
            $errors.Add([pscustomobject]@{ device=$device.key; error="Backup endpoint is no longer registered: $($device.flow)/$($device.endpointId)" })
            continue
        }
        $temporarilyEnabled = $false
        try {
            $restore = Get-AudioBackupDeviceRestoreArguments -Device $device
            if ($restore.RequiresActiveEndpoint -and -not $endpoint.Active) {
                Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible $true
                $temporarilyEnabled = $true
                Start-Sleep -Milliseconds 500
                $endpoint = @(Get-WindowsAudioInventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
                if (-not $endpoint.Active) { throw "Backup endpoint could not be activated: $($device.key)" }
            }
            $propertyArguments = @{ Endpoint=$endpoint }
            foreach ($property in @('format', 'name', 'icon')) {
                if ($restore.Touched -contains $property) {
                    $parameterName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
                    $propertyArguments[$parameterName] = $device.$property
                }
            }
            if ($propertyArguments.Count -gt 1) { Set-WindowsAudioEndpointProperties @propertyArguments }
            if ($restore.Volume.Count -gt 0) {
                $volumeArguments = $restore.Volume
                Set-WindowsAudioEndpointVolume -Endpoint $endpoint @volumeArguments
                $actualVolume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                if ($restore.Volume.ContainsKey('Decibels') -and [Math]::Abs([double]$restore.Volume.Decibels - [double]$actualVolume.decibels) -gt 0.11) { throw "Volume-level verification failed for '$($device.key)'." }
                if ($restore.Volume.ContainsKey('Muted') -and [bool]$restore.Volume.Muted -ne [bool]$actualVolume.muted) { throw "Mute verification failed for '$($device.key)'." }
                $verifiedVolumeKeys.Add([string]$device.key)
            }
            if (($restore.Touched -contains 'enabled') -or $temporarilyEnabled) { Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible ([bool]$device.enabled) }
        }
        catch {
            $errors.Add([pscustomobject]@{ device=$device.key; error=$_.Exception.Message })
        }
        finally {
            if ($temporarilyEnabled) { Set-WindowsAudioEndpointVisibility -EndpointId $endpoint.FullEndpointId -Visible ([bool]$device.enabled) -ErrorAction SilentlyContinue }
        }
    }

    if ([bool]$backup.priorityIncluded) {
        try {
            $priorityFlows = @($backup.priorityFlows)
            $priorityEndpointsProperty = $backup.PSObject.Properties['priorityEndpoints']
            $priorityEndpointIds = if ($null -eq $priorityEndpointsProperty) { @() } else { @($priorityEndpointsProperty.Value | ForEach-Object { "$($_.flow)/$($_.endpointId)" }) }
            foreach ($default in @($backup.defaults | Where-Object { $priorityFlows -contains $_.flow })) {
                if ([string]::IsNullOrWhiteSpace([string]$default.endpointId)) { throw "Backup cannot restore an absent default endpoint for $($default.flow)/$($default.role)." }
                Set-WindowsAudioDefaultEndpoint -EndpointId ([string]$default.endpointId) -Role ([string]$default.role)
            }
            $assignments = [Collections.Generic.List[object]]::new()
            foreach ($device in @($backup.devices | Where-Object {
                $identity = "$($_.flow)/$($_.endpointId)"
                $priorityFlows -contains $_.flow -and $priorityEndpointIds -contains $identity
            })) {
                for ($roleIndex = 0; $roleIndex -lt 3; $roleIndex++) {
                    $role = @('console', 'multimedia', 'communications')[$roleIndex]
                    $level = $device.levels.PSObject.Properties[$role].Value
                    $assignments.Add([ordered]@{ flow=$device.flow; endpointId=$device.endpointId; roleIndex=$roleIndex; hasValue=($null -ne $level); level=$level })
                }
            }
            $plan = [ordered]@{ version=1; machineIdSha256=(Get-AudioMachineHash); assignments=@($assignments) }
            $planPath = Join-Path $backupDirectory 'undo-priority-plan.json'
            [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            try {
                & (Join-Path $PSScriptRoot 'Set-AudioPriority.ps1') -Mode Controller -PlanPath $planPath -Json | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Priority restore worker exited with code $LASTEXITCODE." }
            }
            finally { Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue }
        }
        catch { $errors.Add([pscustomobject]@{ device='priority'; error=$_.Exception.Message }) }
    }

    $postInventory = @(Get-WindowsAudioInventory)
    foreach ($difference in @(Get-AudioBackupDifferences -Backup $backup -Inventory $postInventory -VerifiedVolumeKeys @($verifiedVolumeKeys))) {
        $errors.Add([pscustomobject]@{ device=$difference.device; error="Verification failed for $($difference.property)." })
    }
    $restored = $errors.Count -eq 0
    $result = [pscustomobject]@{ restored=$restored; verified=$restored; backup=$resolvedBackup; devices=@($backup.devices).Count; errors=@($errors) }
    $text = $result | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $text, [Text.UTF8Encoding]::new($false)) }
    elseif ($Json) { Write-Output $text }
    elseif ($restored) { Write-Output "Audio state restored from $resolvedBackup" }
    else { [Console]::Error.WriteLine("Audio state restore completed with $($errors.Count) error(s).") }
    exit $(if ($restored) { 0 } else { 1 })
}
catch {
    $result = [pscustomobject]@{ restored=$false; backup=$BackupPath; error=$_.Exception.Message }
    $text = $result | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $text, [Text.UTF8Encoding]::new($false)) }
    elseif ($Json) { Write-Output $text }
    else { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
