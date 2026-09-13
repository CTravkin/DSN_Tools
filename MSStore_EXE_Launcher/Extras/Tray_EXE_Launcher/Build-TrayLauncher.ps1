[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$ProcessName,
    [Parameter(Mandatory)][string]$TrayIconName,
    [Parameter(Mandatory)][string]$TrayMenuItemName,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Arguments = '',
    [string]$WindowClass = '',
    [string]$WindowTitle = '',
    [ValidateRange(1,20)][int]$RetryCount = 5,
    [ValidateRange(50,5000)][int]$RetryDelayMilliseconds = 400,
    [string]$IconPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'Common\BuildHelpers.psm1') -Force
$expandedTarget = [Environment]::ExpandEnvironmentVariables($TargetPath)
if (-not [IO.Path]::IsPathRooted($expandedTarget)) { throw 'TargetPath must be absolute after environment expansion' }
foreach ($value in @($TrayIconName,$TrayMenuItemName)) { if ([string]::IsNullOrWhiteSpace($value)) { throw 'Tray selectors cannot be empty' } }
$replacement = @{
    TARGET_PATH=(ConvertTo-CSharpLiteral $TargetPath); ARGUMENTS=(ConvertTo-CSharpLiteral $Arguments); PROCESS_NAME=(ConvertTo-CSharpLiteral ([IO.Path]::GetFileNameWithoutExtension($ProcessName)))
    WINDOW_CLASS=(ConvertTo-CSharpLiteral $WindowClass); WINDOW_TITLE=(ConvertTo-CSharpLiteral $WindowTitle); TRAY_ICON_NAME=(ConvertTo-CSharpLiteral $TrayIconName)
    TRAY_MENU_ITEM_NAME=(ConvertTo-CSharpLiteral $TrayMenuItemName); RETRY_COUNT=[string]$RetryCount; RETRY_DELAY=[string]$RetryDelayMilliseconds
}
$references = @('System.Windows.Forms.dll',(Resolve-FrameworkAssembly 'UIAutomationClient'),(Resolve-FrameworkAssembly 'UIAutomationTypes'),(Resolve-FrameworkAssembly 'WindowsBase'))
$result = Invoke-TemplateLauncherBuild -TemplatePath (Join-Path $PSScriptRoot 'TrayLauncher.cs.template') -OutputPath $OutputPath -Replacement $replacement -Reference $references -IconPath $IconPath
Write-Output "Built tray launcher: $result"
