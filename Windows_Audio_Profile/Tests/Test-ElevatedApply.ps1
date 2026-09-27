[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utilityRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsAudioProfile-Elevated-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $testRoot 'Backups'
$originalProfilePath = Join-Path $testRoot 'original.json'
$changedProfilePath = Join-Path $testRoot 'changed.json'
$backupPath = $null
$applied = $false

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-JsonScript {
    param([string]$Script, [string[]]$Arguments)
    $stderr = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.err')
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2> $stderr
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    $rawError = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
    [pscustomobject]@{
        ExitCode=$exitCode
        Output=[string](@($output) -join "`n")
        Error=if($null -eq $rawError){''}else{[string]$rawError}
    }
}

function Get-ProfileDifferenceCount {
    param([Parameter(Mandatory)][string]$Path)
    Import-Module (Join-Path $utilityRoot 'WindowsAudioProfile.psm1') -Force
    $profile = Import-AudioProfile -Path $Path
    $inventory = @(Get-WindowsAudioInventory)
    $resolved = Resolve-AudioProfileDevices -Profile $profile -Inventory $inventory
    @(Get-AudioProfileDifferences -Profile $profile -ResolvedDevices $resolved -Inventory $inventory).Count
}

function Assert-EffectiveProfileDefaults {
    param([Parameter(Mandatory)][string]$Path)
    Import-Module (Join-Path $utilityRoot 'WindowsAudioProfile.psm1') -Force
    $profile = Import-AudioProfile -Path $Path
    $inventory = @(Get-WindowsAudioInventory)
    $resolved = Resolve-AudioProfileDevices -Profile $profile -Inventory $inventory
    $assignments = @(Get-AudioPriorityAssignments -Profile $profile -ResolvedDevices $resolved -Inventory $inventory)
    foreach ($flow in @('render','capture')) {
        foreach ($role in @('console','multimedia','communications')) {
            $preferredCandidates = @($assignments | Where-Object { $_.Flow -eq $flow -and $_.Role -eq $role } | Sort-Object Level -Descending | ForEach-Object {
                $assignment = $_
                $matches = @($inventory | Where-Object { $_.Flow -eq $flow -and $_.EndpointId -eq $assignment.EndpointId -and $_.Active })
                if ($matches.Count -gt 0) { $matches[0] }
            } | Where-Object { $null -ne $_ })
            $preferred = if ($preferredCandidates.Count -gt 0) { $preferredCandidates[0] } else { $null }
            if ($null -eq $preferred) { continue }
            $actual = Get-WindowsAudioDefaultEndpoint -Flow $flow -Role $role
            Assert-True ([string]::Equals([string]$preferred.FullEndpointId, [string]$actual, [StringComparison]::OrdinalIgnoreCase)) "Effective default mismatch for $flow/$role."
        }
    }
}

try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this integration test from an elevated Windows PowerShell 5.1 session.'
    }
    $initialTrustedInstallerStatus = (Get-Service -Name TrustedInstaller).Status

    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Import-Module (Join-Path $utilityRoot 'WindowsAudioProfile.psm1') -Force
    $inventoryForPlan = @(Get-WindowsAudioInventory)
    $priorityEndpoint = @($inventoryForPlan | Where-Object { -not $_.NeverSetAsDefault })[0]
    $currentLevel = $priorityEndpoint.Levels.console
    $noopPlanPath = Join-Path $testRoot 'noop-priority-plan.json'
    $noopPlan = [ordered]@{
        version=1; machineIdSha256=(Get-AudioMachineHash)
        assignments=@([ordered]@{ flow=$priorityEndpoint.Flow; endpointId=$priorityEndpoint.EndpointId; roleIndex=0; hasValue=($null -ne $currentLevel); level=$currentLevel })
    }
    [IO.File]::WriteAllText($noopPlanPath, ($noopPlan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $noopPriority = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Set-AudioPriority.ps1') -Arguments @('-Mode', 'Controller', '-PlanPath', $noopPlanPath, '-Json')
    Assert-True ($noopPriority.ExitCode -eq 0) "No-op priority controller failed: $($noopPriority.Error)"
    $noopPriorityReport = $noopPriority.Output | ConvertFrom-Json
    Assert-True ($noopPriorityReport.stagingProtected -eq $true -and $noopPriorityReport.planHashVerified -eq $true) 'Priority controller must report protected staging and cross-boundary plan verification.'

    $export = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Export-AudioProfile.ps1') -Arguments @('-OutputPath', $originalProfilePath, '-Json')
    Assert-True ($export.ExitCode -eq 0) 'Initial profile export failed.'
    $original = Get-Content -Raw -LiteralPath $originalProfilePath | ConvertFrom-Json

    $activeEndpoints = @($inventoryForPlan | Where-Object { $_.Active })
    Assert-True ($activeEndpoints.Count -ge 2) 'Strict rollback integration needs two active endpoints.'
    $firstActive = $activeEndpoints[0]
    $secondActive = $activeEndpoints[1]
    $firstProfileDevice = @($original.devices | Where-Object { $_.match.flow -eq $firstActive.Flow -and $_.match.endpointId -eq $firstActive.EndpointId })[0]
    $secondProfileDevice = @($original.devices | Where-Object { $_.match.flow -eq $secondActive.Flow -and $_.match.endpointId -eq $secondActive.EndpointId })[0]
    $secondVolume = Get-WindowsAudioEndpointVolume -Endpoint $secondActive
    $strictFailurePath = Join-Path $testRoot 'strict-failure.json'
    $strictFailureProfile = [ordered]@{
        schemaVersion=1; target=$original.target
        devices=@(
            [ordered]@{ key='rollback-name'; required=$true; match=$firstProfileDevice.match; settings=[ordered]@{ name=($firstActive.Name + ' [WAP rollback test]') } },
            [ordered]@{ key='rollback-volume'; required=$true; match=$secondProfileDevice.match; settings=[ordered]@{ volume=[ordered]@{ decibels=([double]$secondVolume.maximumDecibels + 1000) } } }
        )
    }
    [IO.File]::WriteAllText($strictFailurePath, ($strictFailureProfile | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $strictFailure = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Apply-AudioProfile.ps1') -Arguments @('-ProfilePath', $strictFailurePath, '-ApplyMode', 'Strict', '-BackupRoot', $backupRoot, '-Json')
    $strictFailureReport = $strictFailure.Output | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$strictFailureReport.backup) -and -not [bool]$strictFailureReport.rolledBack) {
        $backupPath = [string]$strictFailureReport.backup
        $applied = $true
    }
    Assert-True ($strictFailure.ExitCode -eq 1 -and $strictFailureReport.rolledBack -eq $true) "Strict failure must rollback before returning: $($strictFailure.Error) $($strictFailure.Output)"
    Assert-True ((Get-ProfileDifferenceCount -Path $originalProfilePath) -eq 0) 'Strict rollback did not restore the original audio state.'

    $changed = Get-Content -Raw -LiteralPath $originalProfilePath | ConvertFrom-Json
    foreach ($device in @($changed.devices)) { [void]$device.PSObject.Properties.Remove('settings') }

    $flowName = if ($null -ne $changed.priority.render) { 'render' } else { 'capture' }
    $flowPriority = $changed.priority.$flowName
    $lists = [Collections.Generic.List[object]]::new()
    $lists.Add($flowPriority.allRoles.leastToMostPreferred)
    if ($null -ne $flowPriority.PSObject.Properties['roles']) {
        foreach ($roleProperty in $flowPriority.roles.PSObject.Properties) { $lists.Add($roleProperty.Value.leastToMostPreferred) }
    }
    foreach ($list in $lists) {
        Assert-True (@($list).Count -ge 2) 'The integration test needs at least two eligible endpoints in one flow.'
        $first = $list[0]
        $list[0] = $list[1]
        $list[1] = $first
    }
    [IO.File]::WriteAllText($changedProfilePath, ($changed | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    $apply = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Apply-AudioProfile.ps1') -Arguments @('-ProfilePath', $changedProfilePath, '-ApplyMode', 'Strict', '-BackupRoot', $backupRoot, '-Json')
    Assert-True ($apply.ExitCode -eq 0) "Strict priority apply failed: $($apply.Error) $($apply.Output)"
    $applyReport = $apply.Output | ConvertFrom-Json
    Assert-True ($applyReport.verified -eq $true) 'Strict priority apply did not verify.'
    $backupPath = [string]$applyReport.backup
    $applied = $true

    Assert-True ((Get-ProfileDifferenceCount -Path $changedProfilePath) -eq 0) 'Changed priority did not match live read-back.'
    Assert-EffectiveProfileDefaults -Path $changedProfilePath

    $undo = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Undo-AudioProfile.ps1') -Arguments @('-BackupPath', $backupPath, '-Json')
    Assert-True ($undo.ExitCode -eq 0) 'Undo failed.'
    $applied = $false

    Assert-True ((Get-ProfileDifferenceCount -Path $originalProfilePath) -eq 0) 'Original priority did not return after Undo.'
    Assert-EffectiveProfileDefaults -Path $originalProfilePath

    $copyRoot = Join-Path $testRoot 'UtilityCopy'
    Copy-Item -LiteralPath $utilityRoot -Destination $copyRoot -Recurse
    Remove-Item -LiteralPath (Join-Path $copyRoot 'Set-AudioPriority.ps1') -Force
    $bestEffort = Invoke-JsonScript -Script (Join-Path $copyRoot 'Apply-AudioProfile.ps1') -Arguments @('-ProfilePath', $changedProfilePath, '-ApplyMode', 'BestEffort', '-BackupRoot', $backupRoot, '-Json')
    if (-not [string]::IsNullOrWhiteSpace($bestEffort.Output)) {
        $bestEffortReport = $bestEffort.Output | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$bestEffortReport.backup)) {
            $backupPath = [string]$bestEffortReport.backup
            $applied = $true
        }
    }
    Assert-True ($bestEffort.ExitCode -eq 2) "BestEffort priority failure must return exit 2: $($bestEffort.Error) $($bestEffort.Output)"
    Assert-True ($bestEffortReport.applied -eq $true -and $bestEffortReport.verified -eq $false) 'BestEffort priority failure must report a partial applied result.'
    $bestEffortUndo = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Undo-AudioProfile.ps1') -Arguments @('-BackupPath', $backupPath, '-Json')
    Assert-True ($bestEffortUndo.ExitCode -eq 0) 'BestEffort cleanup Undo failed.'
    $applied = $false
    Assert-True ((Get-ProfileDifferenceCount -Path $originalProfilePath) -eq 0) 'BestEffort cleanup did not restore the original state.'
    Assert-True ((Get-Service -Name TrustedInstaller).Status -eq $initialTrustedInstallerStatus) 'TrustedInstaller service state was not restored.'
    Assert-True (@(Get-ScheduledTask -TaskName 'DSN-WindowsAudioProfile-*' -ErrorAction SilentlyContinue).Count -eq 0) 'Temporary priority task was not removed.'
    Assert-True (@(Get-ChildItem -LiteralPath $env:ProgramData -Directory -Filter 'DSNTools-WindowsAudioProfile-*' -ErrorAction SilentlyContinue).Count -eq 0) 'Protected priority staging directory was not removed.'
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Write-Output 'PASS: elevated priority apply, verification, and undo'
}
catch {
    if ($applied) {
        $recovery = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Undo-AudioProfile.ps1') -Arguments @('-BackupPath', $backupPath, '-Json')
        if ($recovery.ExitCode -ne 0) { Write-Error "The test changed priority and emergency Undo failed. Preserve and use backup: $backupPath" }
        else { $applied = $false }
    }
    if (-not $applied -and (Test-Path -LiteralPath $testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    throw
}
