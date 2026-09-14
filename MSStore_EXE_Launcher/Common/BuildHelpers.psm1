Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-CSharpLiteral {
    param([AllowEmptyString()][string]$Value)

    $builder = [Text.StringBuilder]::new('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        switch ($character) {
            '"' { [void]$builder.Append('\"') }
            '\' { [void]$builder.Append('\\') }
            "`r" { [void]$builder.Append('\r') }
            "`n" { [void]$builder.Append('\n') }
            "`t" { [void]$builder.Append('\t') }
            default {
                if ($code -lt 32 -or $code -eq 0x2028 -or $code -eq 0x2029 -or
                    [char]::IsSurrogate($character)) {
                    [void]$builder.AppendFormat('\u{0:X4}', $code)
                }
                else { [void]$builder.Append($character) }
            }
        }
    }
    [void]$builder.Append('"')
    $builder.ToString()
}

function Resolve-StoreAppId {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][object[]]$Catalog
    )

    $matches = @($Catalog | Where-Object { [string]::Equals([string]$_.Name, $AppName, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -eq 0) { throw "No registered application has the exact name '$AppName'" }
    if ($matches.Count -gt 1) { throw "The name '$AppName' matches multiple registered applications; specify -AppId" }
    $appId = [string]$matches[0].AppID
    if (-not (Test-StoreAppId -AppId $appId)) { throw "The registered application '$AppName' has an invalid AUMID" }
    $appId
}

function Test-StoreAppId {
    param([AllowEmptyString()][string]$AppId)

    -not [string]::IsNullOrWhiteSpace($AppId) -and
        $AppId.Length -le 255 -and
        $AppId -match '^[A-Za-z0-9][A-Za-z0-9._-]*![A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Get-FrameworkCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler csc.exe was not found' }
    $compiler
}

function Resolve-FrameworkAssembly {
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $env:WINDIR "Microsoft.NET\assembly\GAC_MSIL\$Name"
    $assembly = Get-ChildItem -LiteralPath $root -Filter "$Name.dll" -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $assembly) { throw "Required .NET Framework assembly is missing: $Name.dll" }
    $assembly.FullName
}

function Invoke-TemplateLauncherBuild {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][hashtable]$Replacement,
        [string[]]$Reference = @(),
        [string]$IconPath,
        [switch]$Force
    )

    $template = (Resolve-Path -LiteralPath $TemplatePath).Path
    $output = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($output) -ine '.exe') { throw 'OutputPath must end with .exe' }
    if ((Test-Path -LiteralPath $output) -and -not $Force) {
        throw "Output already exists; use -Force to replace it: $output"
    }
    $parent = Split-Path -Parent $output
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $source = [IO.File]::ReadAllText($template, [Text.UTF8Encoding]::new($false, $true))
    $tokens = @([regex]::Matches($source, '__[A-Z0-9_]+__') | ForEach-Object { $_.Value } | Select-Object -Unique)
    foreach ($token in $tokens) {
        $key = $token.Substring(2, $token.Length - 4)
        if (-not $Replacement.ContainsKey($key)) { throw "Template contains an unresolved token: $token" }
        $source = $source.Replace($token, [string]$Replacement[$key])
    }
    foreach ($key in $Replacement.Keys) {
        if ($tokens -notcontains "__$key`__") { throw "Replacement does not exist in template: $key" }
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DSNLauncherBuild-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $sourcePath = Join-Path $tempRoot 'Launcher.cs'
        $compiled = Join-Path $tempRoot 'Launcher.exe'
        [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
        $arguments = @('/nologo','/optimize+','/target:winexe','/platform:anycpu',"/out:$compiled")
        foreach ($assembly in $Reference) { $arguments += "/reference:$assembly" }
        if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
            $resolvedIcon = (Resolve-Path -LiteralPath $IconPath).Path
            if ([IO.Path]::GetExtension($resolvedIcon) -ine '.ico') { throw 'IconPath must point to an .ico file' }
            $arguments += "/win32icon:$resolvedIcon"
        }
        $arguments += $sourcePath
        $compilerOutput = @(& (Get-FrameworkCompiler) @arguments 2>&1)
        $compilerExitCode = $LASTEXITCODE
        if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $compiled -PathType Leaf)) {
            throw "C# compilation failed with exit code $compilerExitCode`n$($compilerOutput -join "`n")"
        }
        Copy-Item -LiteralPath $compiled -Destination $output -Force:$Force
        $output
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

Export-ModuleMember -Function ConvertTo-CSharpLiteral,Resolve-StoreAppId,Test-StoreAppId,Get-FrameworkCompiler,Resolve-FrameworkAssembly,Invoke-TemplateLauncherBuild
