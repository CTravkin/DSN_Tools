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

try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this integration test from an elevated Windows PowerShell 5.1 session.'
    }
    $initialTrustedInstallerStatus = (Get-Service -Name TrustedInstaller).Status

    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $export = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Export-AudioProfile.ps1') -Arguments @('-OutputPath', $originalProfilePath, '-Json')
    Assert-True ($export.ExitCode -eq 0) 'Initial profile export failed.'
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

    $auditChanged = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Test-AudioProfile.ps1') -Arguments @('-ProfilePath', $changedProfilePath, '-Json')
    Assert-True ($auditChanged.ExitCode -eq 0) 'Changed priority did not pass audit.'

    $undo = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Undo-AudioProfile.ps1') -Arguments @('-BackupPath', $backupPath, '-Json')
    Assert-True ($undo.ExitCode -eq 0) 'Undo failed.'
    $applied = $false

    $auditOriginal = Invoke-JsonScript -Script (Join-Path $utilityRoot 'Test-AudioProfile.ps1') -Arguments @('-ProfilePath', $originalProfilePath, '-Json')
    Assert-True ($auditOriginal.ExitCode -eq 0) 'Original priority did not return after Undo.'
    Assert-True ((Get-Service -Name TrustedInstaller).Status -eq $initialTrustedInstallerStatus) 'TrustedInstaller service state was not restored.'
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Write-Output 'PASS: elevated priority apply, verification, and undo'
}
catch {
    if ($applied) {
        Write-Error "The test changed priority and could not undo it. Preserve and use backup: $backupPath"
    }
    throw
}
