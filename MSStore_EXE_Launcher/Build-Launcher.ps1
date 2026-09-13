[CmdletBinding(DefaultParameterSetName='ById')]
param(
    [Parameter(Mandatory,ParameterSetName='ById')][string]$AppId,
    [Parameter(Mandatory,ParameterSetName='ByName')][string]$AppName,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$IconPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common\BuildHelpers.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $AppId = Resolve-StoreAppId -AppName $AppName -Catalog @(Get-StartApps)
}
if ([string]::IsNullOrWhiteSpace($AppId) -or $AppId -match '[\x00-\x1F]') { throw 'AppId must be a non-empty AUMID without control characters' }

$result = Invoke-TemplateLauncherBuild -TemplatePath (Join-Path $PSScriptRoot 'Launcher.cs.template') -OutputPath $OutputPath -Replacement @{ APP_ID=(ConvertTo-CSharpLiteral $AppId) } -Reference @('System.Windows.Forms.dll') -IconPath $IconPath
Write-Output "Built MS Store launcher: $result"
