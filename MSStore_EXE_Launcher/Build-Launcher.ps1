[CmdletBinding(DefaultParameterSetName='ById')]
param(
    [Parameter(Mandatory,ParameterSetName='ById')][string]$AppId,
    [Parameter(Mandatory,ParameterSetName='ByName')][string]$AppName,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$IconPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common\BuildHelpers.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $AppId = Resolve-StoreAppId -AppName $AppName -Catalog @(Get-StartApps)
}
if (-not (Test-StoreAppId -AppId $AppId)) { throw 'AppId must be a valid package-family and application AUMID' }

$result = Invoke-TemplateLauncherBuild -TemplatePath (Join-Path $PSScriptRoot 'Launcher.cs.template') -OutputPath $OutputPath -Replacement @{ APP_ID=(ConvertTo-CSharpLiteral $AppId) } -Reference @('System.Windows.Forms.dll') -IconPath $IconPath -Force:$Force
Write-Output "Built MS Store launcher: $result"
