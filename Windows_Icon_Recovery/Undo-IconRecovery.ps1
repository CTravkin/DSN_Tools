[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param([Parameter(Mandatory)][string]$BackupPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IconRecovery.psm1') -Force

try {
    if ($PSCmdlet.ShouldProcess($BackupPath, 'Restore icon files and attributes from backup')) {
        Restore-IconRecoveryBackup -BackupPath $BackupPath | ConvertTo-Json -Depth 4
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
