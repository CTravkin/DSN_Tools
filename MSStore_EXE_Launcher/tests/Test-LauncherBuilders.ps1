$ErrorActionPreference = 'Stop'

$utilityRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DSNLaunchers-' + [guid]::NewGuid().ToString('N'))

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

function Invoke-Diagnostic {
    param([string]$Path, [string]$Argument)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Path
    $start.Arguments = $Argument
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    $output = $process.StandardOutput.ReadToEnd().Trim()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Diagnostic failed for $Path with exit code $($process.ExitCode)" }
    $output
}

function Invoke-TrayActionSelection {
    param([string]$Path, [bool]$HasWindow, [bool]$HasTrayIcon)

    $escapedPath = $Path.Replace("'", "''")
    $code = @"
`$assembly = [Reflection.Assembly]::LoadFile('$escapedPath')
`$type = `$assembly.GetType('TrayLauncher', `$true)
`$method = `$type.GetMethod('DetermineAction', [Reflection.BindingFlags]'NonPublic,Static')
`$method.Invoke(`$null, @(`$$HasWindow, `$$HasTrayIcon))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    (& powershell.exe -NoProfile -EncodedCommand $encoded | Select-Object -Last 1).Trim()
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Import-Module (Join-Path $utilityRoot 'Common\BuildHelpers.psm1') -Force

    Assert-Equal '"a\\b\"c"' (ConvertTo-CSharpLiteral 'a\b"c') 'C# literal escaping is unsafe'
    $catalog = @(
        [pscustomobject]@{ Name='Duplicate'; AppID='Package.One!App' },
        [pscustomobject]@{ Name='Duplicate'; AppID='Package.Two!App' }
    )
    try {
        Resolve-StoreAppId -AppName 'Duplicate' -Catalog $catalog | Out-Null
        throw 'Ambiguous Store app name was accepted'
    }
    catch {
        if ($_.Exception.Message -notmatch 'multiple') { throw }
    }

    $storeOutput = Join-Path $testRoot 'Store Fixture.exe'
    & (Join-Path $utilityRoot 'Build-Launcher.ps1') -AppId 'Example.Package_123!App' -OutputPath $storeOutput
    Assert-Equal 'Example.Package_123!App' (Invoke-Diagnostic $storeOutput '--print-aumid') 'Store AUMID was not embedded'

    $target = Join-Path $testRoot 'fixture target.exe'
    Set-Content -LiteralPath $target -Value 'fixture'
    $desktopOutput = Join-Path $testRoot 'Desktop Fixture.exe'
    & (Join-Path $utilityRoot 'Extras\Desktop_EXE_Launcher\Build-DesktopLauncher.ps1') -TargetPath $target -Arguments '--profile "Test User"' -ProcessName 'FixtureProcess' -WindowClass 'FixtureWindow' -OutputPath $desktopOutput
    $desktopConfig = Invoke-Diagnostic $desktopOutput '--print-config' | ConvertFrom-Json
    Assert-Equal $target $desktopConfig.targetPath 'Desktop target was not embedded'
    Assert-Equal '--profile "Test User"' $desktopConfig.arguments 'Desktop arguments were not embedded'
    Assert-Equal 'FixtureProcess' $desktopConfig.processName 'Desktop process was not embedded'
    Assert-Equal 'FixtureWindow' $desktopConfig.windowClass 'Desktop window class was not embedded'

    $trayOutput = Join-Path $testRoot 'Tray Fixture.exe'
    & (Join-Path $utilityRoot 'Extras\Tray_EXE_Launcher\Build-TrayLauncher.ps1') -TargetPath $target -ProcessName 'FixtureProcess' -TrayIconName 'Fixture Tray' -TrayMenuItemName 'Open Fixture' -RetryCount 4 -RetryDelayMilliseconds 250 -OutputPath $trayOutput
    $trayConfig = Invoke-Diagnostic $trayOutput '--print-config' | ConvertFrom-Json
    Assert-Equal 'Fixture Tray' $trayConfig.trayIconName 'Tray icon selector was not embedded'
    Assert-Equal 'Open Fixture' $trayConfig.trayMenuItemName 'Tray menu selector was not embedded'
    Assert-Equal 4 $trayConfig.retryCount 'Tray retry count was not embedded'
    Assert-Equal 250 $trayConfig.retryDelayMilliseconds 'Tray retry delay was not embedded'

    Assert-Equal 'activate' (Invoke-TrayActionSelection $trayOutput $true $true) 'Usable window must win over tray'
    Assert-Equal 'open-tray' (Invoke-TrayActionSelection $trayOutput $false $true) 'Tray icon must be used when no window exists'
    Assert-Equal 'launch' (Invoke-TrayActionSelection $trayOutput $false $false) 'Application must launch when no running UI exists'

    Write-Output 'PASS: Store, desktop, and tray launcher builders'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
