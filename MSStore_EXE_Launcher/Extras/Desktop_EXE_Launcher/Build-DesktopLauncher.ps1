[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$ProcessName,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Arguments = '',
    [string]$WindowClass = '',
    [string]$WindowTitle = '',
    [switch]$IncludeHiddenWindow,
    [string]$IconPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'Common\BuildHelpers.psm1') -Force
$expandedTarget = [Environment]::ExpandEnvironmentVariables($TargetPath)
if (-not [IO.Path]::IsPathRooted($expandedTarget)) { throw 'TargetPath must be absolute after environment expansion' }
$process = [IO.Path]::GetFileNameWithoutExtension($ProcessName)
$replacement = @{
    TARGET_PATH=(ConvertTo-CSharpLiteral $TargetPath); ARGUMENTS=(ConvertTo-CSharpLiteral $Arguments); PROCESS_NAME=(ConvertTo-CSharpLiteral $process)
    WINDOW_CLASS=(ConvertTo-CSharpLiteral $WindowClass); WINDOW_TITLE=(ConvertTo-CSharpLiteral $WindowTitle); INCLUDE_HIDDEN=$(if($IncludeHiddenWindow){'true'}else{'false'})
}
$result = Invoke-TemplateLauncherBuild -TemplatePath (Join-Path $PSScriptRoot 'DesktopLauncher.cs.template') -OutputPath $OutputPath -Replacement $replacement -Reference @('System.Windows.Forms.dll') -IconPath $IconPath
Write-Output "Built desktop launcher: $result"
