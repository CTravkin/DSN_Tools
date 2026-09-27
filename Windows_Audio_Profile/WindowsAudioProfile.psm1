Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-AudioObjectProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-AudioUInt16 {
    param([byte[]]$Bytes, [int]$Offset)
    [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Get-AudioUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    [BitConverter]::ToUInt32($Bytes, $Offset)
}

function ConvertFrom-AudioWaveFormat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $offset = 0
    if ($Bytes.Length -ge 48 -and (Get-AudioUInt16 -Bytes $Bytes -Offset 8) -in @(1, 3, 0xFFFE)) {
        $offset = 8
    }
    if ($Bytes.Length -lt ($offset + 18)) { throw 'Audio format data is shorter than WAVEFORMATEX.' }

    $formatTag = Get-AudioUInt16 -Bytes $Bytes -Offset $offset
    $channels = Get-AudioUInt16 -Bytes $Bytes -Offset ($offset + 2)
    $sampleRate = Get-AudioUInt32 -Bytes $Bytes -Offset ($offset + 4)
    $bits = Get-AudioUInt16 -Bytes $Bytes -Offset ($offset + 14)
    $extraSize = Get-AudioUInt16 -Bytes $Bytes -Offset ($offset + 16)
    $validBits = $bits
    $channelMask = 0
    $encoding = switch ($formatTag) { 1 { 'pcm' } 3 { 'ieeeFloat' } default { 'unknown' } }
    $subFormat = $null
    $extensible = $formatTag -eq 0xFFFE
    if ($extensible) {
        if ($extraSize -lt 22 -or $Bytes.Length -lt ($offset + 40)) { throw 'WAVEFORMATEXTENSIBLE data is incomplete.' }
        $validBits = Get-AudioUInt16 -Bytes $Bytes -Offset ($offset + 18)
        $channelMask = Get-AudioUInt32 -Bytes $Bytes -Offset ($offset + 20)
        $guidBytes = [byte[]]::new(16)
        [Array]::Copy($Bytes, $offset + 24, $guidBytes, 0, 16)
        $subFormat = [guid]::new($guidBytes)
        if ($subFormat -eq [guid]'00000001-0000-0010-8000-00aa00389b71') { $encoding = 'pcm' }
        elseif ($subFormat -eq [guid]'00000003-0000-0010-8000-00aa00389b71') { $encoding = 'ieeeFloat' }
    }

    [pscustomobject][ordered]@{
        channels = [int]$channels
        sampleRateHz = [int64]$sampleRate
        bitsPerSample = [int]$bits
        validBitsPerSample = [int]$validBits
        encoding = $encoding
        channelMask = [int64]$channelMask
        extensible = $extensible
    }
}

function ConvertTo-AudioWaveFormatBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Format)

    $channels = [int](Get-AudioObjectProperty -Object $Format -Name 'channels')
    $sampleRate = [int64](Get-AudioObjectProperty -Object $Format -Name 'sampleRateHz')
    $bits = [int](Get-AudioObjectProperty -Object $Format -Name 'bitsPerSample')
    if ($channels -lt 1 -or $sampleRate -lt 1 -or $bits -lt 1) { throw 'Audio format requires positive channels, sampleRateHz, and bitsPerSample.' }
    $validBitsValue = Get-AudioObjectProperty -Object $Format -Name 'validBitsPerSample'
    $validBits = if ($null -eq $validBitsValue) { $bits } else { [int]$validBitsValue }
    $encodingValue = Get-AudioObjectProperty -Object $Format -Name 'encoding'
    $encoding = if ([string]::IsNullOrWhiteSpace([string]$encodingValue)) { 'pcm' } else { [string]$encodingValue }
    $maskValue = Get-AudioObjectProperty -Object $Format -Name 'channelMask'
    $channelMask = if ($null -ne $maskValue) { [uint32]$maskValue } elseif ($channels -eq 1) { [uint32]4 } elseif ($channels -eq 2) { [uint32]3 } else { [uint32]0 }
    $subFormat = switch ($encoding) {
        'pcm' { [guid]'00000001-0000-0010-8000-00aa00389b71' }
        'ieeeFloat' { [guid]'00000003-0000-0010-8000-00aa00389b71' }
        default { throw "Unsupported audio encoding '$encoding'." }
    }
    $bytesPerSample = [int][Math]::Ceiling($bits / 8.0)
    $blockAlign = $channels * $bytesPerSample
    $averageBytes = $sampleRate * $blockAlign
    if ($blockAlign -gt [uint16]::MaxValue -or $averageBytes -gt [uint32]::MaxValue) { throw 'Audio format values are out of range.' }

    $useExtensible = -not (Test-AudioObjectProperty -Object $Format -Name 'extensible') -or [bool]$Format.extensible
    if (-not $useExtensible) {
        $classicTag = if ($encoding -eq 'pcm') { [uint16]1 } else { [uint16]3 }
        $classicBytes = [byte[]]::new(18)
        [Array]::Copy([BitConverter]::GetBytes($classicTag), 0, $classicBytes, 0, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$channels), 0, $classicBytes, 2, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$sampleRate), 0, $classicBytes, 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$averageBytes), 0, $classicBytes, 8, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$blockAlign), 0, $classicBytes, 12, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$bits), 0, $classicBytes, 14, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint16]0), 0, $classicBytes, 16, 2)
        return $classicBytes
    }

    $bytes = [byte[]]::new(40)
    [Array]::Copy([BitConverter]::GetBytes([uint16]0xFFFE), 0, $bytes, 0, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$channels), 0, $bytes, 2, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$sampleRate), 0, $bytes, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$averageBytes), 0, $bytes, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$blockAlign), 0, $bytes, 12, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$bits), 0, $bytes, 14, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]22), 0, $bytes, 16, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$validBits), 0, $bytes, 18, 2)
    [Array]::Copy([BitConverter]::GetBytes($channelMask), 0, $bytes, 20, 4)
    [Array]::Copy($subFormat.ToByteArray(), 0, $bytes, 24, 16)
    $bytes
}

function Get-WindowsAudioInventory {
    [CmdletBinding()]
    param()

    $audioRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
    $propertyNames = @{
        Name = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
        EndpointName = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
        DeviceInstanceId = '{b3f8fa53-0004-438e-9003-51a46e139bfc},2'
        ContainerId = '{9637b4b9-11ee-4c35-b43c-7b2452c993cc},1'
        HardwareId = '{a8b865dd-2e3d-4094-ad97-e593a70c75d6},8'
        HardwareIdSpecific = '{80f111c3-b103-42e1-afb6-db7a6fa8be1f},0'
        DriverIdentity = '{83da6326-97a6-4088-9453-a1923f573b29},3'
        Icon = '{259abffc-50a7-47ce-af08-68c9a7d73366},12'
        Format = '{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'
        NeverSet = '{f3e80bef-1723-4ff2-bcc4-7f83dc5e46d4},3'
    }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($flowDefinition in @(@('render', 'Render', '0'), @('capture', 'Capture', '1'))) {
        $flow = $flowDefinition[0]
        $registryFlow = $flowDefinition[1]
        $fullIdFlow = $flowDefinition[2]
        $flowPath = Join-Path $audioRoot $registryFlow
        if (-not (Test-Path -LiteralPath $flowPath)) { continue }
        foreach ($endpointKey in Get-ChildItem -LiteralPath $flowPath) {
            $propertiesPath = Join-Path $endpointKey.PSPath 'Properties'
            if (-not (Test-Path -LiteralPath $propertiesPath)) { continue }
            $properties = Get-ItemProperty -LiteralPath $propertiesPath
            $endpointValues = Get-ItemProperty -LiteralPath $endpointKey.PSPath
            $readProperty = {
                param([string]$Name)
                $property = $properties.PSObject.Properties[$Name]
                if ($null -eq $property) { return $null }
                $property.Value
            }
            $hardwareIds = [Collections.Generic.List[string]]::new()
            foreach ($hardwareProperty in @($propertyNames.HardwareId, $propertyNames.HardwareIdSpecific)) {
                $value = & $readProperty $hardwareProperty
                foreach ($item in @($value)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$item) -and -not $hardwareIds.Contains([string]$item)) { $hardwareIds.Add([string]$item) }
                }
            }
            $rawFormatBytes = & $readProperty $propertyNames.Format
            $format = if ($null -ne $rawFormatBytes) {
                try { ConvertFrom-AudioWaveFormat -Bytes ([byte[]]$rawFormatBytes) } catch { $null }
            }
            else { $null }
            $neverSetValue = & $readProperty $propertyNames.NeverSet
            $stateProperty = $endpointValues.PSObject.Properties['DeviceState']
            $state = if ($null -eq $stateProperty) { 0 } else { [uint32]$stateProperty.Value }
            $levels = [ordered]@{}
            foreach ($roleIndex in 0..2) {
                $levelProperty = $endpointValues.PSObject.Properties["Level:$roleIndex"]
                $levels[@('console', 'multimedia', 'communications')[$roleIndex]] = if ($null -eq $levelProperty) { $null } else { [int64]$levelProperty.Value }
            }
            $endpointId = $endpointKey.PSChildName
            $fullEndpointId = "{0.0.$fullIdFlow.00000000}.$endpointId"
            $stableId = try { Get-WindowsAudioEndpointStableId -EndpointId $fullEndpointId } catch { $null }
            $result.Add([pscustomobject][ordered]@{
                Flow = $flow
                EndpointId = $endpointId
                FullEndpointId = $fullEndpointId
                StableId = $stableId
                Name = [string](& $readProperty $propertyNames.Name)
                EndpointName = [string](& $readProperty $propertyNames.EndpointName)
                DeviceInstanceId = [string](& $readProperty $propertyNames.DeviceInstanceId)
                ContainerId = [string](& $readProperty $propertyNames.ContainerId)
                HardwareIds = @($hardwareIds)
                DriverIdentity = [string](& $readProperty $propertyNames.DriverIdentity)
                DriverProvider = $null
                Icon = [string](& $readProperty $propertyNames.Icon)
                Format = $format
                DeviceState = $state
                Enabled = -not [bool]($state -band 2)
                Active = [bool]($state -band 1)
                NeverSetAsDefault = $null -ne $neverSetValue -and [int64]$neverSetValue -ne 0
                Levels = [pscustomobject]$levels
                Volume = $null
            })
        }
    }
    @($result)
}

function Initialize-AudioInterop {
    [CmdletBinding()]
    param([string]$SourcePath = (Join-Path $PSScriptRoot 'CoreAudio.cs'))

    if ('DSNTools.WindowsAudioProfile.CoreAudio' -as [type]) { return }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Core Audio source is missing: $SourcePath" }
    Add-Type -Path $SourcePath
}

function Get-WindowsAudioEndpointVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Endpoint)

    Initialize-AudioInterop
    $state = [DSNTools.WindowsAudioProfile.CoreAudio]::GetVolume([string]$Endpoint.FullEndpointId)
    [pscustomobject][ordered]@{
        percent = [Math]::Round([double]$state.Scalar * 100, 4)
        decibels = [Math]::Round([double]$state.Decibels, 4)
        minimumDecibels = [Math]::Round([double]$state.MinimumDecibels, 4)
        maximumDecibels = [Math]::Round([double]$state.MaximumDecibels, 4)
        incrementDecibels = [Math]::Round([double]$state.IncrementDecibels, 4)
        muted = [bool]$state.Muted
        fixed = [Math]::Abs([double]$state.MaximumDecibels - [double]$state.MinimumDecibels) -lt 0.0001
    }
}

function Get-WindowsAudioEndpointStableId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EndpointId)

    Initialize-AudioInterop
    [DSNTools.WindowsAudioProfile.CoreAudio]::GetStableId($EndpointId)
}

function Get-WindowsAudioDefaultEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('render', 'capture')][string]$Flow,
        [Parameter(Mandatory)][ValidateSet('console', 'multimedia', 'communications')][string]$Role
    )

    Initialize-AudioInterop
    $flowIndex = if ($Flow -eq 'render') { 0 } else { 1 }
    $roleIndex = @('console', 'multimedia', 'communications').IndexOf($Role)
    [DSNTools.WindowsAudioProfile.CoreAudio]::GetDefaultEndpoint($flowIndex, $roleIndex)
}

function Set-WindowsAudioEndpointVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [Nullable[double]]$Percent,
        [Nullable[double]]$Decibels,
        [Nullable[bool]]$Muted
    )

    Initialize-AudioInterop
    if ($null -ne $Percent -and $null -ne $Decibels) { throw 'Specify either Percent or Decibels, not both.' }
    if ($null -ne $Percent) {
        if ($Percent -lt 0 -or $Percent -gt 100) { throw 'Percent must be between 0 and 100.' }
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetVolumeScalar([string]$Endpoint.FullEndpointId, [single]($Percent / 100.0))
    }
    elseif ($null -ne $Decibels) {
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetVolumeDecibels([string]$Endpoint.FullEndpointId, [single]$Decibels)
    }
    if ($null -ne $Muted) {
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetMute([string]$Endpoint.FullEndpointId, [bool]$Muted)
    }
}

function Set-WindowsAudioDefaultEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EndpointId,
        [Parameter(Mandatory)][ValidateSet('console', 'multimedia', 'communications')][string]$Role
    )

    Initialize-AudioInterop
    [DSNTools.WindowsAudioProfile.CoreAudio]::SetDefaultEndpoint($EndpointId, @('console', 'multimedia', 'communications').IndexOf($Role))
}

function Set-WindowsAudioEndpointVisibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EndpointId,
        [Parameter(Mandatory)][bool]$Visible
    )

    Initialize-AudioInterop
    [DSNTools.WindowsAudioProfile.CoreAudio]::SetEndpointVisibility($EndpointId, $Visible)
}

function Set-WindowsAudioEndpointProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint,
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Icon,
        [AllowNull()]$Format
    )

    Initialize-AudioInterop
    if ($PSBoundParameters.ContainsKey('Format') -and $null -ne $Format) {
        $bytes = ConvertTo-AudioWaveFormatBytes -Format $Format
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetBlobProperty(
            [string]$Endpoint.FullEndpointId,
            'f19f064d-082c-4e27-bc73-6882a1bb8e4c',
            0,
            $bytes
        )
    }
    if ($PSBoundParameters.ContainsKey('Name')) {
        if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Audio endpoint name cannot be empty.' }
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetStringProperty(
            [string]$Endpoint.FullEndpointId,
            'a45c254e-df1c-4efd-8020-67d146a850e0',
            2,
            $Name
        )
    }
    if ($PSBoundParameters.ContainsKey('Icon')) {
        if ([string]::IsNullOrWhiteSpace($Icon)) { throw 'Audio endpoint icon cannot be empty.' }
        [DSNTools.WindowsAudioProfile.CoreAudio]::SetStringProperty(
            [string]$Endpoint.FullEndpointId,
            '259abffc-50a7-47ce-af08-68c9a7d73366',
            12,
            $Icon
        )
    }
}

function Test-AudioObjectProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-AudioAllowedProperties {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )

    if ($null -eq $Object) { return }
    foreach ($property in $Object.PSObject.Properties) {
        if ($Allowed -notcontains $property.Name) { throw "Unknown property '$($property.Name)' in $Context." }
    }
}

function Assert-AudioBooleanProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if (-not (Test-AudioObjectProperty -Object $Object -Name $Name)) { return }
    if ((Get-AudioObjectProperty -Object $Object -Name $Name) -isnot [bool]) {
        throw "$Context.$Name must be a JSON Boolean."
    }
}

function Test-AudioRawNumber {
    param([AllowNull()]$Value)
    $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
}

function Test-AudioRawInteger {
    param([AllowNull()]$Value)
    if (-not (Test-AudioRawNumber -Value $Value)) { return $false }
    $number = [double]$Value
    -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -eq [Math]::Truncate($number)
}

function Assert-AudioRawString {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context,
        [switch]$Required,
        [switch]$NonEmpty
    )
    if (-not $Object.ContainsKey($Name)) {
        if ($Required) { throw "$Context requires $Name." }
        return
    }
    $value = $Object[$Name]
    if ($value -isnot [string] -or ($NonEmpty -and [string]::IsNullOrWhiteSpace([string]$value))) {
        throw "$Context.$Name must be a JSON string$(if ($NonEmpty) { ' with at least one character' })."
    }
}

function Assert-AudioRawAllowedProperties {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )
    foreach ($name in $Object.Keys) {
        if ($Allowed -notcontains [string]$name) { throw "Unknown property '$name' in $Context." }
    }
}

function ConvertFrom-AudioJsonDocument {
    param([Parameter(Mandatory)][string]$Json)
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216
    $serializer.DeserializeObject($Json)
}

function Read-AudioJsonSnapshot {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedSha256, [string]$Context = 'JSON file')
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') }
    finally { $sha.Dispose() }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "$Context expected SHA-256 must contain 64 hexadecimal characters." }
        if (-not [string]::Equals($actual, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) { throw "$Context hash verification failed." }
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    [pscustomobject]@{ Json=$json; Sha256=$actual }
}

function Assert-AudioRawPriorityOrder {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Order,
        [Parameter(Mandatory)][string]$Context
    )
    if (-not $Order.ContainsKey('leastToMostPreferred')) { throw "$Context requires leastToMostPreferred." }
    $items = $Order['leastToMostPreferred']
    if ($items -isnot [array] -or @($items).Count -lt 1) { throw "$Context.leastToMostPreferred must be a non-empty JSON array." }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item)) { throw "$Context.leastToMostPreferred must contain non-empty strings." }
        if (-not $seen.Add([string]$item)) { throw "$Context.leastToMostPreferred must not contain duplicates." }
    }
}

function Assert-AudioRawProfileContract {
    param([Parameter(Mandatory)]$Raw)

    if ($Raw -isnot [Collections.IDictionary]) { throw 'Audio profile root must be a JSON object.' }
    if (-not $Raw.ContainsKey('schemaVersion') -or -not (Test-AudioRawInteger -Value $Raw['schemaVersion']) -or [int64]$Raw['schemaVersion'] -ne 1) {
        throw 'Unsupported audio profile schemaVersion; expected integer 1.'
    }
    if ($Raw.ContainsKey('$schema') -and $Raw['$schema'] -isnot [string]) { throw 'profile root.$schema must be a JSON string.' }

    if ($Raw.ContainsKey('profile')) {
        $metadata = $Raw['profile']
        if ($metadata -isnot [Collections.IDictionary]) { throw 'profile metadata must be a JSON object.' }
        Assert-AudioRawString -Object $metadata -Name 'name' -Context 'profile' -NonEmpty
        Assert-AudioRawString -Object $metadata -Name 'description' -Context 'profile'
        Assert-AudioRawString -Object $metadata -Name 'exportedAtUtc' -Context 'profile'
    }
    if ($Raw.ContainsKey('target')) {
        $target = $Raw['target']
        if ($target -isnot [Collections.IDictionary]) { throw 'target must be a JSON object.' }
        Assert-AudioRawString -Object $target -Name 'computerName' -Context 'target'
        Assert-AudioRawString -Object $target -Name 'machineIdSha256' -Context 'target'
        if ($target.ContainsKey('machineIdSha256') -and [string]$target['machineIdSha256'] -notmatch '^[0-9a-fA-F]{64}$') { throw 'target.machineIdSha256 must contain 64 hexadecimal characters.' }
        Assert-AudioRawString -Object $target -Name 'binding' -Context 'target'
        if ($target.ContainsKey('binding') -and [string]$target['binding'] -notin @('strict', 'none')) { throw 'target.binding must be strict or none.' }
        if ($target.ContainsKey('binding') -and [string]$target['binding'] -eq 'strict' -and -not $target.ContainsKey('machineIdSha256')) { throw 'target.machineIdSha256 is required when target.binding is strict.' }
    }

    if (-not $Raw.ContainsKey('devices') -or $Raw['devices'] -isnot [array] -or @($Raw['devices']).Count -lt 1) {
        throw 'Audio profile must contain at least one device in a JSON array.'
    }
    foreach ($device in @($Raw['devices'])) {
        if ($device -isnot [Collections.IDictionary]) { throw 'Every devices item must be a JSON object.' }
        Assert-AudioRawString -Object $device -Name 'key' -Context 'device' -Required -NonEmpty
        $key = [string]$device['key']
        if ($device.ContainsKey('required') -and $device['required'] -isnot [bool]) { throw "Device '$key'.required must be a JSON Boolean." }
        if (-not $device.ContainsKey('match') -or $device['match'] -isnot [Collections.IDictionary]) { throw "Device '$key' requires a match object." }
        $match = $device['match']
        Assert-AudioRawString -Object $match -Name 'flow' -Context "Device '$key' match" -Required
        if ([string]$match['flow'] -notin @('render','capture')) { throw "Device '$key' match.flow must be render or capture." }
        foreach ($name in @('endpointId','stableId','containerId','deviceInstanceId','driverProvider','driverIdentity')) { Assert-AudioRawString -Object $match -Name $name -Context "Device '$key' match" }
        if ($match.ContainsKey('stableId') -and [string]::IsNullOrWhiteSpace([string]$match['stableId'])) { throw "Device '$key' match.stableId must be a non-empty JSON string." }
        if ($match.ContainsKey('endpointId') -and [string]$match['endpointId'] -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { throw "Device '$key' match.endpointId must be a braced GUID." }
        if ($match.ContainsKey('hardwareIds')) {
            $hardwareIds = $match['hardwareIds']
            if ($hardwareIds -isnot [array]) { throw "Device '$key' match.hardwareIds must be a JSON array." }
            $seenHardwareIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($hardwareId in $hardwareIds) {
                if ($hardwareId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$hardwareId)) { throw "Device '$key' match.hardwareIds must contain non-empty strings." }
                if (-not $seenHardwareIds.Add([string]$hardwareId)) { throw "Device '$key' match.hardwareIds must not contain duplicates." }
            }
        }

        if (-not $device.ContainsKey('settings')) { continue }
        $settings = $device['settings']
        if ($settings -isnot [Collections.IDictionary]) { throw "Device '$key' settings must be a JSON object." }
        foreach ($name in @('name','icon')) { Assert-AudioRawString -Object $settings -Name $name -Context "Device '$key' settings" -NonEmpty }
        if ($settings.ContainsKey('enabled') -and $settings['enabled'] -isnot [bool]) { throw "Device '$key' settings.enabled must be a JSON Boolean." }
        if ($settings.ContainsKey('volume')) {
            $volume = $settings['volume']
            if ($volume -isnot [Collections.IDictionary] -or $volume.Count -lt 1) { throw "Device '$key' volume must be a JSON object with at least one property." }
            if ($volume.ContainsKey('percent') -and -not (Test-AudioRawNumber -Value $volume['percent'])) { throw "Device '$key' volume.percent must be a JSON number." }
            if ($volume.ContainsKey('decibels') -and -not (Test-AudioRawNumber -Value $volume['decibels'])) { throw "Device '$key' volume.decibels must be a JSON number." }
            if ($volume.ContainsKey('percent') -and ([double]$volume['percent'] -lt 0 -or [double]$volume['percent'] -gt 100)) { throw "Device '$key' volume.percent must be between 0 and 100." }
            if ($volume.ContainsKey('percent') -and $volume.ContainsKey('decibels')) { throw "Device '$key' volume must contain either percent or decibels, not both." }
            if ($volume.ContainsKey('muted') -and $volume['muted'] -isnot [bool]) { throw "Device '$key' volume.muted must be a JSON Boolean." }
        }
        if ($settings.ContainsKey('format')) {
            $format = $settings['format']
            if ($format -isnot [Collections.IDictionary]) { throw "Device '$key' format must be a JSON object." }
            foreach ($name in @('channels','sampleRateHz','bitsPerSample')) {
                if (-not $format.ContainsKey($name) -or -not (Test-AudioRawInteger -Value $format[$name]) -or [int64]$format[$name] -lt 1) { throw "Device '$key' format.$name must be a positive JSON integer." }
            }
            if ($format.ContainsKey('validBitsPerSample') -and (-not (Test-AudioRawInteger -Value $format['validBitsPerSample']) -or [int64]$format['validBitsPerSample'] -lt 1)) { throw "Device '$key' format.validBitsPerSample must be a positive JSON integer." }
            if ($format.ContainsKey('channelMask') -and (-not (Test-AudioRawInteger -Value $format['channelMask']) -or [int64]$format['channelMask'] -lt 0)) { throw "Device '$key' format.channelMask must be a non-negative JSON integer." }
            if ($format.ContainsKey('encoding') -and ($format['encoding'] -isnot [string] -or [string]$format['encoding'] -notin @('pcm','ieeeFloat'))) { throw "Device '$key' format.encoding must be pcm or ieeeFloat." }
            if ($format.ContainsKey('extensible') -and $format['extensible'] -isnot [bool]) { throw "Device '$key' format.extensible must be a JSON Boolean." }
        }
    }

    if (-not $Raw.ContainsKey('priority')) { return }
    $priority = $Raw['priority']
    if ($priority -isnot [Collections.IDictionary]) { throw 'priority must be a JSON object.' }
    foreach ($flow in @('render','capture')) {
        if (-not $priority.ContainsKey($flow)) { continue }
        $flowPriority = $priority[$flow]
        if ($flowPriority -isnot [Collections.IDictionary]) { throw "priority.$flow must be a JSON object." }
        if (-not $flowPriority.ContainsKey('allRoles') -or $flowPriority['allRoles'] -isnot [Collections.IDictionary]) { throw "priority.$flow requires an allRoles object." }
        Assert-AudioRawPriorityOrder -Order $flowPriority['allRoles'] -Context "priority.$flow.allRoles"
        if ($flowPriority.ContainsKey('roles')) {
            $roles = $flowPriority['roles']
            if ($roles -isnot [Collections.IDictionary]) { throw "priority.$flow.roles must be a JSON object." }
            foreach ($role in @('console','multimedia','communications')) {
                if (-not $roles.ContainsKey($role)) { continue }
                if ($roles[$role] -isnot [Collections.IDictionary]) { throw "priority.$flow.roles.$role must be a JSON object." }
                Assert-AudioRawPriorityOrder -Order $roles[$role] -Context "priority.$flow.roles.$role"
            }
        }
    }
}

function Assert-AudioRawBackupContract {
    param([Parameter(Mandatory)]$Raw)

    if ($Raw -isnot [Collections.IDictionary]) { throw 'Audio backup root must be a JSON object.' }
    Assert-AudioRawAllowedProperties -Object $Raw -Allowed @('version','createdAtUtc','machineIdSha256','sourceProfile','priorityIncluded','priorityFlows','priorityEndpoints','devices','defaults') -Context 'audio backup root'
    if (-not $Raw.ContainsKey('version') -or -not (Test-AudioRawInteger -Value $Raw['version']) -or [int64]$Raw['version'] -ne 1) { throw 'Unsupported audio backup version; expected integer 1.' }
    foreach ($name in @('createdAtUtc','machineIdSha256','sourceProfile')) { Assert-AudioRawString -Object $Raw -Name $name -Context 'audio backup' -Required }
    if ([string]$Raw['machineIdSha256'] -notmatch '^[0-9a-fA-F]{64}$') { throw 'audio backup.machineIdSha256 must contain 64 hexadecimal characters.' }
    if (-not $Raw.ContainsKey('priorityIncluded') -or $Raw['priorityIncluded'] -isnot [bool]) { throw 'audio backup.priorityIncluded must be a JSON Boolean.' }

    foreach ($arrayName in @('priorityFlows','priorityEndpoints','devices','defaults')) {
        if (-not $Raw.ContainsKey($arrayName) -or $Raw[$arrayName] -isnot [array]) { throw "audio backup.$arrayName must be a JSON array." }
    }
    $seenFlows = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($flow in @($Raw['priorityFlows'])) {
        if ($flow -isnot [string] -or [string]$flow -notin @('render','capture') -or -not $seenFlows.Add([string]$flow)) { throw 'audio backup.priorityFlows must contain unique render or capture strings.' }
    }
    if ([bool]$Raw['priorityIncluded'] -ne (@($Raw['priorityFlows']).Count -gt 0)) { throw 'audio backup.priorityIncluded must match priorityFlows.' }

    $seenPriorityEndpoints = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($endpoint in @($Raw['priorityEndpoints'])) {
        if ($endpoint -isnot [Collections.IDictionary]) { throw 'Every audio backup priorityEndpoints item must be a JSON object.' }
        Assert-AudioRawAllowedProperties -Object $endpoint -Allowed @('flow','endpointId') -Context 'audio backup priority endpoint'
        Assert-AudioRawString -Object $endpoint -Name 'flow' -Context 'audio backup priority endpoint' -Required
        Assert-AudioRawString -Object $endpoint -Name 'endpointId' -Context 'audio backup priority endpoint' -Required
        if ([string]$endpoint['flow'] -notin @('render','capture')) { throw 'audio backup priority endpoint.flow must be render or capture.' }
        if ([string]$endpoint['endpointId'] -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { throw 'audio backup priority endpoint.endpointId must be a braced GUID.' }
        if (@($Raw['priorityFlows']) -notcontains [string]$endpoint['flow']) { throw 'audio backup priority endpoint belongs to a flow that is not included.' }
        if (-not $seenPriorityEndpoints.Add("$($endpoint['flow'])/$($endpoint['endpointId'])")) { throw 'audio backup priorityEndpoints must not contain duplicates.' }
    }

    $allowedTouched = @('name','icon','enabled','format','volume','volume.level','volume.muted')
    $seenDevices = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $deviceIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($device in @($Raw['devices'])) {
        if ($device -isnot [Collections.IDictionary]) { throw 'Every audio backup devices item must be a JSON object.' }
        Assert-AudioRawAllowedProperties -Object $device -Allowed @('key','flow','endpointId','fullEndpointId','name','icon','enabled','format','volume','levels','touched') -Context 'audio backup device'
        foreach ($name in @('key','flow','endpointId','fullEndpointId','name','icon')) { Assert-AudioRawString -Object $device -Name $name -Context 'audio backup device' -Required }
        $key = [string]$device['key']
        if ([string]::IsNullOrWhiteSpace($key) -or -not $seenDevices.Add($key)) { throw 'audio backup device keys must be non-empty and unique.' }
        if ([string]$device['flow'] -notin @('render','capture')) { throw "Audio backup device '$key'.flow must be render or capture." }
        if ([string]$device['endpointId'] -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { throw "Audio backup device '$key'.endpointId must be a braced GUID." }
        if (-not $deviceIdentities.Add("$($device['flow'])/$($device['endpointId'])")) { throw 'audio backup devices must not contain duplicate flow/endpoint identities.' }
        $expectedFullFlow = if ([string]$device['flow'] -eq 'render') { '0' } else { '1' }
        if ([string]$device['fullEndpointId'] -notmatch ("^\{0\.0\.$expectedFullFlow\.00000000\}\." + [regex]::Escape([string]$device['endpointId']) + '$')) { throw "Audio backup device '$key'.fullEndpointId does not match its flow and endpointId." }
        if ($device['enabled'] -isnot [bool]) { throw "Audio backup device '$key'.enabled must be a JSON Boolean." }
        if ($device['touched'] -isnot [array]) { throw "Audio backup device '$key'.touched must be a JSON array." }
        $seenTouched = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($touched in @($device['touched'])) {
            if ($touched -isnot [string] -or [string]$touched -notin $allowedTouched -or -not $seenTouched.Add([string]$touched)) { throw "Audio backup device '$key'.touched contains an invalid or duplicate value." }
        }
        if ($seenTouched.Contains('name') -and [string]::IsNullOrWhiteSpace([string]$device['name'])) { throw "Audio backup device '$key' is missing its touched name snapshot." }
        if ($seenTouched.Contains('icon') -and [string]::IsNullOrWhiteSpace([string]$device['icon'])) { throw "Audio backup device '$key' is missing its touched icon snapshot." }

        $format = $device['format']
        if ($null -ne $format) {
            if ($format -isnot [Collections.IDictionary]) { throw "Audio backup device '$key'.format must be a JSON object or null." }
            Assert-AudioRawAllowedProperties -Object $format -Allowed @('channels','sampleRateHz','bitsPerSample','validBitsPerSample','encoding','channelMask','extensible') -Context "audio backup device '$key' format"
            foreach ($name in @('channels','sampleRateHz','bitsPerSample','validBitsPerSample','channelMask')) {
                if ($format.ContainsKey($name) -and -not (Test-AudioRawInteger -Value $format[$name])) { throw "Audio backup device '$key'.format.$name must be a JSON integer." }
            }
            if ($format.ContainsKey('encoding') -and ($format['encoding'] -isnot [string] -or [string]$format['encoding'] -notin @('pcm','ieeeFloat','unknown'))) { throw "Audio backup device '$key'.format.encoding is invalid." }
            if ($format.ContainsKey('extensible') -and $format['extensible'] -isnot [bool]) { throw "Audio backup device '$key'.format.extensible must be a JSON Boolean." }
        }

        $volume = $device['volume']
        if ($null -ne $volume) {
            if ($volume -isnot [Collections.IDictionary]) { throw "Audio backup device '$key'.volume must be a JSON object or null." }
            Assert-AudioRawAllowedProperties -Object $volume -Allowed @('percent','decibels','minimumDecibels','maximumDecibels','incrementDecibels','muted','fixed') -Context "audio backup device '$key' volume"
            foreach ($name in @('percent','decibels','minimumDecibels','maximumDecibels','incrementDecibels')) {
                if ($volume.ContainsKey($name) -and -not (Test-AudioRawNumber -Value $volume[$name])) { throw "Audio backup device '$key'.volume.$name must be a JSON number." }
            }
            foreach ($name in @('muted','fixed')) {
                if ($volume.ContainsKey($name) -and $volume[$name] -isnot [bool]) { throw "Audio backup device '$key'.volume.$name must be a JSON Boolean." }
            }
        }
        if (($seenTouched.Contains('volume') -or $seenTouched.Contains('volume.level') -or $seenTouched.Contains('volume.muted')) -and $null -eq $volume) { throw "Audio backup device '$key' is missing its touched volume snapshot." }
        if (($seenTouched.Contains('volume') -or $seenTouched.Contains('volume.level')) -and -not $volume.ContainsKey('decibels')) { throw "Audio backup device '$key' is missing its touched volume level." }
        if (($seenTouched.Contains('volume') -or $seenTouched.Contains('volume.muted')) -and -not $volume.ContainsKey('muted')) { throw "Audio backup device '$key' is missing its touched mute value." }
        if ($seenTouched.Contains('format') -and $null -eq $format) { throw "Audio backup device '$key' is missing its touched format snapshot." }

        $levels = $device['levels']
        if ($levels -isnot [Collections.IDictionary]) { throw "Audio backup device '$key'.levels must be a JSON object." }
        Assert-AudioRawAllowedProperties -Object $levels -Allowed @('console','multimedia','communications') -Context "audio backup device '$key' levels"
        foreach ($role in @('console','multimedia','communications')) {
            if (-not $levels.ContainsKey($role)) { throw "Audio backup device '$key'.levels requires $role." }
            if ($null -ne $levels[$role] -and -not (Test-AudioRawInteger -Value $levels[$role])) { throw "Audio backup device '$key'.levels.$role must be a JSON integer or null." }
        }
    }

    if ([bool]$Raw['priorityIncluded']) {
        if ($seenPriorityEndpoints.Count -lt 1) { throw 'audio backup.priorityEndpoints must not be empty when priorityIncluded is true.' }
        foreach ($flow in @($Raw['priorityFlows'])) {
            if (@($Raw['priorityEndpoints'] | Where-Object { [string]$_['flow'] -eq [string]$flow }).Count -lt 1) { throw "audio backup.priorityEndpoints must include at least one endpoint for $flow." }
        }
        foreach ($identity in $seenPriorityEndpoints) {
            if (-not $deviceIdentities.Contains($identity)) { throw "Audio backup priority endpoint '$identity' has no matching device snapshot." }
        }
    }

    $seenDefaults = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($default in @($Raw['defaults'])) {
        if ($default -isnot [Collections.IDictionary]) { throw 'Every audio backup defaults item must be a JSON object.' }
        Assert-AudioRawAllowedProperties -Object $default -Allowed @('flow','role','endpointId') -Context 'audio backup default'
        foreach ($name in @('flow','role','endpointId')) { Assert-AudioRawString -Object $default -Name $name -Context 'audio backup default' -Required }
        if ([string]$default['flow'] -notin @('render','capture')) { throw 'audio backup default.flow must be render or capture.' }
        if ([string]$default['role'] -notin @('console','multimedia','communications')) { throw 'audio backup default.role is invalid.' }
        if (@($Raw['priorityFlows']) -notcontains [string]$default['flow']) { throw 'audio backup default belongs to a flow that is not included.' }
        $defaultFlowIndex = if ([string]$default['flow'] -eq 'render') { '0' } else { '1' }
        if ([string]$default['endpointId'] -notmatch ("^\{0\.0\.$defaultFlowIndex\.00000000\}\.\{[0-9a-fA-F-]{36}\}$")) { throw 'audio backup default.endpointId must be a full MMDevice endpoint ID for its flow.' }
        $defaultEndpointId = ([regex]::Match([string]$default['endpointId'], '\{[0-9a-fA-F-]{36}\}$')).Value
        if (-not $seenPriorityEndpoints.Contains("$($default['flow'])/$defaultEndpointId")) { throw 'audio backup default must reference an exact priorityEndpoints member.' }
        if (-not $seenDefaults.Add("$($default['flow'])/$($default['role'])")) { throw 'audio backup defaults must not contain duplicate flow/role entries.' }
    }
    if ([bool]$Raw['priorityIncluded'] -and @($Raw['defaults']).Count -ne (3 * @($Raw['priorityFlows']).Count)) { throw 'audio backup defaults must contain all three roles for every priority flow.' }
}

function Assert-AudioProfileShape {
    param([Parameter(Mandatory)]$Document)

    Assert-AudioAllowedProperties -Object $Document -Allowed @('$schema','schemaVersion','profile','target','devices','priority') -Context 'profile root'
    Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $Document 'profile') -Allowed @('name','description','exportedAtUtc') -Context 'profile metadata'
    Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $Document 'target') -Allowed @('computerName','machineIdSha256','binding') -Context 'target'
    foreach ($device in @(Get-AudioObjectProperty $Document 'devices')) {
        $key = [string](Get-AudioObjectProperty $device 'key')
        Assert-AudioAllowedProperties -Object $device -Allowed @('key','required','match','settings') -Context "device '$key'"
        Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $device 'match') -Allowed @('flow','endpointId','stableId','containerId','deviceInstanceId','hardwareIds','driverProvider','driverIdentity') -Context "device '$key' match"
        $settings = Get-AudioObjectProperty $device 'settings'
        Assert-AudioAllowedProperties -Object $settings -Allowed @('name','icon','enabled','volume','format') -Context "device '$key' settings"
        Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $settings 'volume') -Allowed @('percent','decibels','muted') -Context "device '$key' volume"
        Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $settings 'format') -Allowed @('channels','sampleRateHz','bitsPerSample','validBitsPerSample','encoding','channelMask','extensible') -Context "device '$key' format"
    }
    $priority = Get-AudioObjectProperty $Document 'priority'
    Assert-AudioAllowedProperties -Object $priority -Allowed @('render','capture') -Context 'priority'
    foreach ($flow in @('render','capture')) {
        $flowPriority = Get-AudioObjectProperty $priority $flow
        if ($null -eq $flowPriority) { continue }
        Assert-AudioAllowedProperties -Object $flowPriority -Allowed @('allRoles','roles') -Context "priority.$flow"
        $allRoles = Get-AudioObjectProperty $flowPriority 'allRoles'
        Assert-AudioAllowedProperties -Object $allRoles -Allowed @('leastToMostPreferred') -Context "priority.$flow.allRoles"
        $roles = Get-AudioObjectProperty $flowPriority 'roles'
        Assert-AudioAllowedProperties -Object $roles -Allowed @('console','multimedia','communications') -Context "priority.$flow.roles"
        foreach ($role in @('console','multimedia','communications')) {
            Assert-AudioAllowedProperties -Object (Get-AudioObjectProperty $roles $role) -Allowed @('leastToMostPreferred') -Context "priority.$flow.roles.$role"
        }
    }
}

function Import-AudioProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedSha256)

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $snapshot = Read-AudioJsonSnapshot -Path $resolvedPath -ExpectedSha256 $ExpectedSha256 -Context 'Audio profile'
    $json = $snapshot.Json
    $rawDocument = ConvertFrom-AudioJsonDocument -Json $json
    Assert-AudioRawProfileContract -Raw $rawDocument
    $document = $json | ConvertFrom-Json
    Assert-AudioProfileShape -Document $document
    if ($null -eq $document -or -not (Test-AudioObjectProperty -Object $document -Name 'schemaVersion') -or [int]$document.schemaVersion -ne 1) {
        throw 'Unsupported audio profile schemaVersion; expected 1.'
    }
    if (-not (Test-AudioObjectProperty -Object $document -Name 'devices')) {
        throw 'Audio profile must contain a devices array.'
    }
    if (@($document.devices).Count -lt 1) {
        throw 'Audio profile must contain at least one device.'
    }

    $target = Get-AudioObjectProperty -Object $document -Name 'target'
    if ($null -ne $target -and (Test-AudioObjectProperty -Object $target -Name 'binding')) {
        $binding = [string](Get-AudioObjectProperty -Object $target -Name 'binding')
        if ($binding -notin @('strict', 'none')) { throw "target.binding must be strict or none; got '$binding'." }
    }

    $seenKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($device in @($document.devices)) {
        $key = [string](Get-AudioObjectProperty -Object $device -Name 'key')
        if ([string]::IsNullOrWhiteSpace($key)) { throw 'Every device requires a non-empty key.' }
        if (-not $seenKeys.Add($key)) { throw "Duplicate device key: $key" }
        Assert-AudioBooleanProperty -Object $device -Name 'required' -Context "Device '$key'"

        $match = Get-AudioObjectProperty -Object $device -Name 'match'
        $flow = [string](Get-AudioObjectProperty -Object $match -Name 'flow')
        if ($flow -notin @('render', 'capture')) { throw "Device '$key' requires match.flow render or capture." }
        if (Test-AudioObjectProperty -Object $match -Name 'endpointId') {
            $endpointId = Get-AudioObjectProperty -Object $match -Name 'endpointId'
            $parsedEndpointId = [guid]::Empty
            if ($endpointId -isnot [string] -or [string]$endpointId -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$' -or -not [guid]::TryParse([string]$endpointId, [ref]$parsedEndpointId)) {
                throw "Device '$key' match.endpointId must be a braced GUID."
            }
        }

        $settings = Get-AudioObjectProperty -Object $device -Name 'settings'
        Assert-AudioBooleanProperty -Object $settings -Name 'enabled' -Context "Device '$key' settings"
        $volume = Get-AudioObjectProperty -Object $settings -Name 'volume'
        if ($null -ne $volume) {
            if (@($volume.PSObject.Properties).Count -lt 1) { throw "Device '$key' volume must contain at least one property." }
            Assert-AudioBooleanProperty -Object $volume -Name 'muted' -Context "Device '$key' volume"
            $hasPercent = Test-AudioObjectProperty -Object $volume -Name 'percent'
            $hasDecibels = Test-AudioObjectProperty -Object $volume -Name 'decibels'
            if ($hasPercent -and $hasDecibels) {
                throw "Device '$key' volume must contain either percent or decibels, not both."
            }
            if ($hasPercent -and ([double]$volume.percent -lt 0 -or [double]$volume.percent -gt 100)) {
                throw "Device '$key' volume.percent must be between 0 and 100."
            }
        }
        $format = Get-AudioObjectProperty -Object $settings -Name 'format'
        if ($null -ne $format) {
            Assert-AudioBooleanProperty -Object $format -Name 'extensible' -Context "Device '$key' format"
            [void](ConvertTo-AudioWaveFormatBytes -Format $format)
        }
    }
    $document | Add-Member -NotePropertyName '_path' -NotePropertyValue $resolvedPath -Force
    $document
}

function Import-AudioBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedSha256)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $backupFile = if (Test-Path -LiteralPath $resolved -PathType Container) { Join-Path $resolved 'state.json' } else { $resolved }
    $snapshot = Read-AudioJsonSnapshot -Path $backupFile -ExpectedSha256 $ExpectedSha256 -Context 'Audio backup'
    $json = $snapshot.Json
    $raw = ConvertFrom-AudioJsonDocument -Json $json
    Assert-AudioRawBackupContract -Raw $raw
    $json | ConvertFrom-Json
}

function Test-AudioIdentityValueEqual {
    param([AllowNull()]$Actual, [AllowNull()]$Expected)
    if ($null -eq $Expected -or [string]::IsNullOrWhiteSpace([string]$Expected)) { return $true }
    if ($null -eq $Actual) { return $false }
    [string]::Equals(([string]$Actual).Trim(), ([string]$Expected).Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Test-AudioEndpointFingerprint {
    param(
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)]$Match,
        [switch]$IgnoreEndpointId,
        [switch]$IgnoreStableId
    )

    if (-not (Test-AudioIdentityValueEqual -Actual $Endpoint.Flow -Expected $Match.flow)) { return $false }
    if (-not $IgnoreEndpointId -and (Test-AudioObjectProperty -Object $Match -Name 'endpointId')) {
        if (-not (Test-AudioIdentityValueEqual -Actual $Endpoint.EndpointId -Expected $Match.endpointId)) { return $false }
    }
    if (-not $IgnoreStableId -and (Test-AudioObjectProperty -Object $Match -Name 'stableId')) {
        $actualStableId = [string](Get-AudioObjectProperty -Object $Endpoint -Name 'StableId')
        if (-not [string]::Equals($actualStableId, [string]$Match.stableId, [StringComparison]::Ordinal)) { return $false }
    }

    foreach ($name in @('containerId', 'deviceInstanceId', 'driverProvider', 'driverIdentity')) {
        if (Test-AudioObjectProperty -Object $Match -Name $name) {
            $actualName = $name.Substring(0,1).ToUpperInvariant() + $name.Substring(1)
            if (-not (Test-AudioIdentityValueEqual -Actual (Get-AudioObjectProperty -Object $Endpoint -Name $actualName) -Expected $Match.$name)) {
                return $false
            }
        }
    }

    if (Test-AudioObjectProperty -Object $Match -Name 'hardwareIds') {
        $expectedIds = @($Match.hardwareIds)
        $actualIds = @(Get-AudioObjectProperty -Object $Endpoint -Name 'HardwareIds')
        foreach ($expectedId in $expectedIds) {
            if (-not @($actualIds | Where-Object { Test-AudioIdentityValueEqual -Actual $_ -Expected $expectedId }).Count) {
                return $false
            }
        }
    }
    $true
}

function Get-AudioStrongFingerprintCount {
    param([Parameter(Mandatory)]$Match)
    $count = 0
    foreach ($name in @('containerId', 'deviceInstanceId', 'hardwareIds')) {
        if (Test-AudioObjectProperty -Object $Match -Name $name) {
            $value = Get-AudioObjectProperty -Object $Match -Name $name
            if ($null -ne $value -and @($value).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]@($value)[0])) { $count++ }
        }
    }
    $count
}

function Get-AudioMachineHash {
    [CmdletBinding()]
    param()

    $machineGuid = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid')
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($machineGuid)
        ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-AudioProfileKey {
    param([Parameter(Mandatory)]$Endpoint, [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$Used)

    $slug = [regex]::Replace(([string]$Endpoint.Name).Trim().ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'device' }
    $baseKey = "$($Endpoint.Flow)-$slug"
    $key = $baseKey
    $suffix = 2
    while (-not $Used.Add($key)) {
        $key = "$baseKey-$suffix"
        $suffix++
    }
    $key
}

function New-AudioProfileDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Inventory,
        [string]$Name = 'Windows audio profile'
    )

    $usedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $keyByEndpoint = @{}
    $devices = [Collections.Generic.List[object]]::new()
    foreach ($endpoint in $Inventory) {
        $key = ConvertTo-AudioProfileKey -Endpoint $endpoint -Used $usedKeys
        $keyByEndpoint["$($endpoint.Flow)/$($endpoint.EndpointId)"] = $key
        $match = [ordered]@{
            flow = $endpoint.Flow
            endpointId = $endpoint.EndpointId
        }
        foreach ($pair in @(
            @('stableId', (Get-AudioObjectProperty -Object $endpoint -Name 'StableId')),
            @('containerId', $endpoint.ContainerId),
            @('deviceInstanceId', $endpoint.DeviceInstanceId),
            @('hardwareIds', @($endpoint.HardwareIds)),
            @('driverIdentity', $endpoint.DriverIdentity)
        )) {
            $value = $pair[1]
            if ($value -is [array]) {
                if (@($value).Count -gt 0) { $match[$pair[0]] = @($value) }
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$value)) { $match[$pair[0]] = $value }
        }

        $settings = [ordered]@{
            name = $endpoint.Name
            enabled = [bool]$endpoint.Enabled
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$endpoint.Icon)) { $settings.icon = $endpoint.Icon }
        if ($null -ne $endpoint.Format) { $settings.format = $endpoint.Format }
        if ($endpoint.Active) {
            try {
                $volume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                $settings.volume = [ordered]@{ percent = $volume.percent; muted = $volume.muted }
            }
            catch {
            }
        }
        $devices.Add([ordered]@{
            key = $key
            required = $true
            match = $match
            settings = $settings
        })
    }

    $priority = [ordered]@{}
    foreach ($flow in @('render', 'capture')) {
        $eligible = @($Inventory | Where-Object { $_.Flow -eq $flow -and -not $_.NeverSetAsDefault })
        if ($eligible.Count -eq 0) { continue }
        $orders = @{}
        foreach ($role in @('console', 'multimedia', 'communications')) {
            $orders[$role] = @($eligible | Sort-Object @{ Expression = {
                $value = Get-AudioObjectProperty -Object $_.Levels -Name $role
                if ($null -eq $value) { [int64]::MinValue } else { [int64]$value }
            } }, @{ Expression = { $_.EndpointId } } | ForEach-Object { $keyByEndpoint["$flow/$($_.EndpointId)"] })
        }
        $flowPriority = [ordered]@{
            allRoles = [ordered]@{ leastToMostPreferred = @($orders.console) }
        }
        $roleOverrides = [ordered]@{}
        foreach ($role in @('multimedia', 'communications')) {
            if ((@($orders[$role]) -join "`n") -ne (@($orders.console) -join "`n")) {
                $roleOverrides[$role] = [ordered]@{ leastToMostPreferred = @($orders[$role]) }
            }
        }
        if ($roleOverrides.Count -gt 0) { $flowPriority.roles = $roleOverrides }
        $priority[$flow] = $flowPriority
    }

    [ordered]@{
        '$schema' = './audio-profile.schema.json'
        schemaVersion = 1
        profile = [ordered]@{ name = $Name; exportedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        target = [ordered]@{
            computerName = $env:COMPUTERNAME
            machineIdSha256 = Get-AudioMachineHash
            binding = 'strict'
        }
        devices = @($devices)
        priority = $priority
    }
}

function Get-AudioIconSourceFile {
    param([Parameter(Mandatory)][string]$Icon)
    $expanded = [Environment]::ExpandEnvironmentVariables($Icon)
    $match = [regex]::Match($expanded, '^(?<path>.*),(?<index>-?\d+)$')
    $path = if ($match.Success) { $match.Groups['path'].Value } else { $expanded }
    if (-not [IO.Path]::IsPathRooted($path)) { throw "Icon source must be an absolute path after environment expansion: $Icon" }
    [IO.Path]::GetFullPath($path)
}

function Test-AudioProfileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][object[]]$Inventory,
        [switch]$IgnoreMachineBinding
    )

    $errors = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[object]]::new()
    try {
        $target = Get-AudioObjectProperty -Object $Profile -Name 'target'
        if (-not $IgnoreMachineBinding -and $null -ne $target -and [string](Get-AudioObjectProperty -Object $target -Name 'binding') -eq 'strict') {
            $expectedHash = [string](Get-AudioObjectProperty -Object $target -Name 'machineIdSha256')
            if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and -not [string]::Equals($expectedHash, (Get-AudioMachineHash), [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Profile machine binding does not match this Windows installation.'
            }
        }
        $resolved = Resolve-AudioProfileDevices -Profile $Profile -Inventory $Inventory
        [void](Get-AudioPriorityAssignments -Profile $Profile -ResolvedDevices $resolved -Inventory $Inventory)
        foreach ($device in @($Profile.devices)) {
            $endpoint = $resolved[[string]$device.key]
            if ($null -eq $endpoint) {
                $warnings.Add([pscustomobject]@{ code='optionalDeviceMissing'; device=$device.key; message='Optional device is not registered.' })
                continue
            }
            $settings = Get-AudioObjectProperty -Object $device -Name 'settings'
            $icon = Get-AudioObjectProperty -Object $settings -Name 'icon'
            if (-not [string]::IsNullOrWhiteSpace([string]$icon)) {
                $source = Get-AudioIconSourceFile -Icon ([string]$icon)
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Icon source is missing for '$($device.key)': $source" }
            }
            $volume = Get-AudioObjectProperty -Object $settings -Name 'volume'
            if ($null -ne $volume -and -not $endpoint.Active) {
                $warnings.Add([pscustomobject]@{ code='volumeRequiresActiveEndpoint'; device=$device.key; message='Volume can only be checked after the endpoint becomes active.' })
            }
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ code='validationFailed'; message=$_.Exception.Message })
        $resolved = @{}
    }
    [pscustomobject][ordered]@{
        valid = $errors.Count -eq 0
        matchedDevices = @($resolved.Values | Where-Object { $null -ne $_ }).Count
        warnings = @($warnings)
        errors = @($errors)
    }
}

function New-AudioBackupDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][hashtable]$ResolvedDevices,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $devices = [Collections.Generic.List[object]]::new()
    foreach ($profileDevice in @($Profile.devices)) {
        $endpoint = $ResolvedDevices[[string]$profileDevice.key]
        if ($null -eq $endpoint) { continue }
        $settings = Get-AudioObjectProperty -Object $profileDevice -Name 'settings'
        $touched = [Collections.Generic.List[string]]::new()
        foreach ($property in @('name', 'icon', 'enabled', 'format')) {
            if (Test-AudioObjectProperty -Object $settings -Name $property) { $touched.Add($property) }
        }
        $volumePatch = Get-AudioObjectProperty -Object $settings -Name 'volume'
        if ($null -ne $volumePatch) {
            if ((Test-AudioObjectProperty -Object $volumePatch -Name 'percent') -or (Test-AudioObjectProperty -Object $volumePatch -Name 'decibels')) { $touched.Add('volume.level') }
            if (Test-AudioObjectProperty -Object $volumePatch -Name 'muted') { $touched.Add('volume.muted') }
        }
        foreach ($property in @('name','icon','format')) {
            if ($touched -notcontains $property) { continue }
            $currentValue = Get-AudioObjectProperty -Object $endpoint -Name ($property.Substring(0,1).ToUpperInvariant() + $property.Substring(1))
            if ($null -eq $currentValue -or ($property -in @('name','icon') -and [string]::IsNullOrWhiteSpace([string]$currentValue))) {
                throw "Cannot create a reversible backup for '$($profileDevice.key)': current $property property is absent."
            }
        }
        $volume = $null
        if (($touched -contains 'volume.level' -or $touched -contains 'volume.muted') -and $endpoint.Active) {
            $volume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
        }
        $devices.Add([ordered]@{
            key = [string]$profileDevice.key
            flow = $endpoint.Flow
            endpointId = $endpoint.EndpointId
            fullEndpointId = $endpoint.FullEndpointId
            name = $endpoint.Name
            icon = $endpoint.Icon
            enabled = [bool]$endpoint.Enabled
            format = $endpoint.Format
            volume = $volume
            levels = $endpoint.Levels
            touched = @($touched)
        })
    }
    $priority = Get-AudioObjectProperty -Object $Profile -Name 'priority'
    $priorityFlows = @(@('render','capture') | Where-Object { $null -ne (Get-AudioObjectProperty -Object $priority -Name $_) })
    $priorityEndpoints = @($Inventory | Where-Object { $priorityFlows -contains $_.Flow -and -not $_.NeverSetAsDefault } | ForEach-Object { [ordered]@{ flow=$_.Flow; endpointId=$_.EndpointId } })
    $defaults = [Collections.Generic.List[object]]::new()
    foreach ($flow in $priorityFlows) {
        foreach ($role in @('console', 'multimedia', 'communications')) {
            $defaultEndpointId = Get-WindowsAudioDefaultEndpoint -Flow $flow -Role $role
            if ([string]::IsNullOrWhiteSpace([string]$defaultEndpointId)) { throw "Cannot create a reversible backup: $flow/$role has no default endpoint." }
            $defaults.Add([ordered]@{ flow=$flow; role=$role; endpointId=$defaultEndpointId })
        }
    }
    [ordered]@{
        version = 1
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        machineIdSha256 = Get-AudioMachineHash
        sourceProfile = [string](Get-AudioObjectProperty -Object $Profile -Name '_path')
        priorityIncluded = $priorityFlows.Count -gt 0
        priorityFlows = @($priorityFlows)
        priorityEndpoints = @($priorityEndpoints)
        devices = @($devices)
        defaults = @($defaults)
    }
}

function Get-AudioBackupDeviceRestoreArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Device)

    $touched = @($Device.touched)
    $volume = @{}
    if ($touched -contains 'volume' -or $touched -contains 'volume.level') {
        if ($null -eq $Device.volume) { throw "Backup device '$($Device.key)' is missing its volume-level snapshot." }
        $volume.Decibels = [double]$Device.volume.decibels
    }
    if ($touched -contains 'volume' -or $touched -contains 'volume.muted') {
        if ($null -eq $Device.volume) { throw "Backup device '$($Device.key)' is missing its mute snapshot." }
        $volume.Muted = [bool]$Device.volume.muted
    }
    [pscustomobject]@{
        Touched = $touched
        Volume = $volume
        RequiresActiveEndpoint = $volume.Count -gt 0
    }
}

function Get-AudioBackupDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Backup,
        [Parameter(Mandatory)][object[]]$Inventory,
        [string[]]$VerifiedVolumeKeys = @()
    )

    $differences = [Collections.Generic.List[object]]::new()
    foreach ($device in @($Backup.devices)) {
        $endpoint = @($Inventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
        if ($null -eq $endpoint) {
            $differences.Add([pscustomobject]@{ device=$device.key; property='endpoint'; expected='present'; actual='missing' })
            continue
        }
        $touched = @($device.touched)
        foreach ($property in @('name','icon','enabled')) {
            if ($touched -notcontains $property) { continue }
            $actualName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
            $expected = Get-AudioObjectProperty -Object $device -Name $property
            $actual = Get-AudioObjectProperty -Object $endpoint -Name $actualName
            $equal = if ($property -eq 'enabled') { [bool]$expected -eq [bool]$actual } else { [string]::Equals([string]$expected, [string]$actual, [StringComparison]::Ordinal) }
            if (-not $equal) { $differences.Add([pscustomobject]@{ device=$device.key; property=$property; expected=$expected; actual=$actual }) }
        }
        if ($touched -contains 'format') {
            foreach ($property in @('channels','sampleRateHz','bitsPerSample','validBitsPerSample','encoding','channelMask','extensible')) {
                $expected = Get-AudioObjectProperty -Object $device.format -Name $property
                $actual = Get-AudioObjectProperty -Object $endpoint.Format -Name $property
                if ([string]$expected -ne [string]$actual) { $differences.Add([pscustomobject]@{ device=$device.key; property="format.$property"; expected=$expected; actual=$actual }) }
            }
        }
        $volumeTouched = $touched -contains 'volume' -or $touched -contains 'volume.level' -or $touched -contains 'volume.muted'
        if ($volumeTouched -and $VerifiedVolumeKeys -notcontains [string]$device.key) {
            if (-not $endpoint.Active) {
                $differences.Add([pscustomobject]@{ device=$device.key; property='volume'; expected='verified'; actual='endpoint inactive' })
            }
            else {
                try {
                    $actualVolume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                    if (($touched -contains 'volume' -or $touched -contains 'volume.level') -and [Math]::Abs([double]$device.volume.decibels - [double]$actualVolume.decibels) -gt 0.11) {
                        $differences.Add([pscustomobject]@{ device=$device.key; property='volume.level'; expected=$device.volume.decibels; actual=$actualVolume.decibels })
                    }
                    if (($touched -contains 'volume' -or $touched -contains 'volume.muted') -and [bool]$device.volume.muted -ne [bool]$actualVolume.muted) {
                        $differences.Add([pscustomobject]@{ device=$device.key; property='volume.muted'; expected=$device.volume.muted; actual=$actualVolume.muted })
                    }
                }
                catch { $differences.Add([pscustomobject]@{ device=$device.key; property='volume'; expected='readable'; actual=$_.Exception.Message }) }
            }
        }
    }

    $priorityFlows = @($Backup.priorityFlows)
    $priorityEndpointsValue = Get-AudioObjectProperty -Object $Backup -Name 'priorityEndpoints'
    $priorityEndpointIds = if ($null -eq $priorityEndpointsValue) { @() } else { @($priorityEndpointsValue | ForEach-Object { "$($_.flow)/$($_.endpointId)" }) }
    foreach ($device in @($Backup.devices | Where-Object {
        $identity = "$($_.flow)/$($_.endpointId)"
        $priorityFlows -contains $_.flow -and $priorityEndpointIds -contains $identity
    })) {
        $endpoint = @($Inventory | Where-Object { $_.Flow -eq $device.flow -and $_.EndpointId -eq $device.endpointId })[0]
        if ($null -eq $endpoint) { continue }
        foreach ($role in @('console','multimedia','communications')) {
            $expected = Get-AudioObjectProperty -Object $device.levels -Name $role
            $actual = Get-AudioObjectProperty -Object $endpoint.Levels -Name $role
            if ($null -eq $expected -and $null -eq $actual) { continue }
            if ($null -eq $expected -or $null -eq $actual -or [int64]$expected -ne [int64]$actual) {
                $differences.Add([pscustomobject]@{ device=$device.key; property="priority.$role"; expected=$expected; actual=$actual })
            }
        }
    }
    foreach ($default in @($Backup.defaults)) {
        $actual = Get-WindowsAudioDefaultEndpoint -Flow ([string]$default.flow) -Role ([string]$default.role)
        if (-not [string]::Equals([string]$default.endpointId, [string]$actual, [StringComparison]::OrdinalIgnoreCase)) {
            $differences.Add([pscustomobject]@{ device=$default.flow; property="default.$($default.role)"; expected=$default.endpointId; actual=$actual })
        }
    }
    @($differences)
}

function Get-AudioProfileDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][hashtable]$ResolvedDevices,
        [Parameter(Mandatory)][object[]]$Inventory,
        [string[]]$VerifiedVolumeKeys = @(),
        [hashtable]$DefaultEndpoints
    )

    $differences = [Collections.Generic.List[object]]::new()
    foreach ($profileDevice in @($Profile.devices)) {
        $key = [string]$profileDevice.key
        $originalEndpoint = $ResolvedDevices[$key]
        if ($null -eq $originalEndpoint) { continue }
        $endpoint = @($Inventory | Where-Object { $_.Flow -eq $originalEndpoint.Flow -and $_.EndpointId -eq $originalEndpoint.EndpointId })[0]
        if ($null -eq $endpoint) {
            $differences.Add([pscustomobject]@{ device=$key; property='endpoint'; expected='present'; actual='missing' })
            continue
        }
        $settings = Get-AudioObjectProperty -Object $profileDevice -Name 'settings'
        foreach ($property in @('name', 'icon', 'enabled')) {
            if (-not (Test-AudioObjectProperty -Object $settings -Name $property)) { continue }
            $actualName = $property.Substring(0,1).ToUpperInvariant() + $property.Substring(1)
            $expected = Get-AudioObjectProperty -Object $settings -Name $property
            $actual = Get-AudioObjectProperty -Object $endpoint -Name $actualName
            $equal = if ($property -eq 'enabled') { [bool]$expected -eq [bool]$actual }
            else { [string]::Equals([string]$expected, [string]$actual, [StringComparison]::OrdinalIgnoreCase) }
            if (-not $equal) { $differences.Add([pscustomobject]@{ device=$key; property=$property; expected=$expected; actual=$actual }) }
        }
        $expectedFormat = Get-AudioObjectProperty -Object $settings -Name 'format'
        if ($null -ne $expectedFormat) {
            foreach ($property in @('channels', 'sampleRateHz', 'bitsPerSample', 'validBitsPerSample', 'encoding', 'channelMask')) {
                if (-not (Test-AudioObjectProperty -Object $expectedFormat -Name $property)) { continue }
                $expected = Get-AudioObjectProperty -Object $expectedFormat -Name $property
                $actual = Get-AudioObjectProperty -Object $endpoint.Format -Name $property
                if ([string]$expected -ne [string]$actual) { $differences.Add([pscustomobject]@{ device=$key; property="format.$property"; expected=$expected; actual=$actual }) }
            }
        }
        $expectedVolume = Get-AudioObjectProperty -Object $settings -Name 'volume'
        if ($null -ne $expectedVolume -and $VerifiedVolumeKeys -notcontains $key) {
            if (-not $endpoint.Active) {
                $differences.Add([pscustomobject]@{ device=$key; property='volume'; expected='configured'; actual='unavailable until endpoint is active' })
            }
            else {
                try {
                $actualVolume = Get-WindowsAudioEndpointVolume -Endpoint $endpoint
                foreach ($property in @('percent', 'decibels')) {
                    if ((Test-AudioObjectProperty -Object $expectedVolume -Name $property) -and [Math]::Abs([double]$expectedVolume.$property - [double]$actualVolume.$property) -gt 0.11) {
                        $differences.Add([pscustomobject]@{ device=$key; property="volume.$property"; expected=$expectedVolume.$property; actual=$actualVolume.$property })
                    }
                }
                if ((Test-AudioObjectProperty -Object $expectedVolume -Name 'muted') -and [bool]$expectedVolume.muted -ne [bool]$actualVolume.muted) {
                    $differences.Add([pscustomobject]@{ device=$key; property='volume.muted'; expected=$expectedVolume.muted; actual=$actualVolume.muted })
                }
                }
                catch {
                    $differences.Add([pscustomobject]@{ device=$key; property='volume'; expected='readable'; actual=$_.Exception.Message })
                }
            }
        }
    }

    $priority = Get-AudioObjectProperty -Object $Profile -Name 'priority'
    if ($null -ne $priority) {
        $assignments = @(Get-AudioPriorityAssignments -Profile $Profile -ResolvedDevices $ResolvedDevices -Inventory $Inventory)
        $keyByEndpoint = @{}
        foreach ($pair in $ResolvedDevices.GetEnumerator()) {
            if ($null -ne $pair.Value) { $keyByEndpoint["$($pair.Value.Flow)/$($pair.Value.EndpointId)"] = [string]$pair.Key }
        }
        foreach ($flow in @('render', 'capture')) {
            foreach ($role in @('console', 'multimedia', 'communications')) {
                $expectedOrder = @($assignments | Where-Object { $_.Flow -eq $flow -and $_.Role -eq $role } | Sort-Object Level | ForEach-Object { $_.Key })
                if ($expectedOrder.Count -eq 0) { continue }
                $actualOrder = @($Inventory | Where-Object { $_.Flow -eq $flow -and -not $_.NeverSetAsDefault } | Sort-Object @{ Expression = {
                    $value = Get-AudioObjectProperty -Object $_.Levels -Name $role
                    if ($null -eq $value) { [int64]::MinValue } else { [int64]$value }
                } }, @{ Expression = { $_.EndpointId } } | ForEach-Object { $keyByEndpoint["$flow/$($_.EndpointId)"] })
                if (($expectedOrder -join "`n") -ne ($actualOrder -join "`n")) {
                    $differences.Add([pscustomobject]@{ device=$flow; property="priority.$role"; expected=$expectedOrder; actual=$actualOrder })
                }
                $preferredCandidates = @($assignments | Where-Object { $_.Flow -eq $flow -and $_.Role -eq $role } | Sort-Object Level -Descending | ForEach-Object {
                    $assignment = $_
                    $matches = @($Inventory | Where-Object { $_.Flow -eq $flow -and $_.EndpointId -eq $assignment.EndpointId -and $_.Active })
                    if ($matches.Count -gt 0) { $matches[0] }
                } | Where-Object { $null -ne $_ })
                $preferredActive = if ($preferredCandidates.Count -gt 0) { $preferredCandidates[0] } else { $null }
                if ($null -ne $preferredActive) {
                    $defaultKey = "$flow/$role"
                    $actualDefault = if ($null -ne $DefaultEndpoints -and $DefaultEndpoints.ContainsKey($defaultKey)) { $DefaultEndpoints[$defaultKey] } else { Get-WindowsAudioDefaultEndpoint -Flow $flow -Role $role }
                    if (-not [string]::Equals([string]$preferredActive.FullEndpointId, [string]$actualDefault, [StringComparison]::OrdinalIgnoreCase)) {
                        $differences.Add([pscustomobject]@{ device=$flow; property="default.$role"; expected=$preferredActive.FullEndpointId; actual=$actualDefault })
                    }
                }
            }
        }
    }
    @($differences)
}

function Get-AudioPriorityRegistryOperations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AudioRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assignments
    )

    foreach ($assignment in $Assignments) {
        $registryFlow = if ([string]$assignment.flow -eq 'render') { 'Render' } elseif ([string]$assignment.flow -eq 'capture') { 'Capture' } else { throw "Invalid priority flow '$($assignment.flow)'." }
        $roleIndex = [int]$assignment.roleIndex
        if ($roleIndex -lt 0 -or $roleIndex -gt 2) { throw "Invalid priority role index '$roleIndex'." }
        $path = Join-Path $AudioRoot "$registryFlow\$($assignment.endpointId)"
        $hasValueProperty = $assignment.PSObject.Properties['hasValue']
        $hasValue = if ($null -eq $hasValueProperty) { $null -ne $assignment.level } else { [bool]$hasValueProperty.Value }
        [pscustomobject]@{
            Path = $path
            Name = "Level:$roleIndex"
            Action = if ($hasValue) { 'Set' } else { 'Remove' }
            Value = if ($hasValue) { [int64]$assignment.level } else { $null }
        }
    }
}

function Set-AudioPriorityRegistryValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AudioRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assignments
    )

    $operations = @(Get-AudioPriorityRegistryOperations -AudioRoot $AudioRoot -Assignments $Assignments)
    foreach ($operation in $operations) {
        if (-not (Test-Path -LiteralPath $operation.Path -PathType Container)) { throw "Audio endpoint registry key is missing: $($operation.Path)" }
        if ($operation.Action -eq 'Set') {
            New-ItemProperty -LiteralPath $operation.Path -Name $operation.Name -PropertyType QWord -Value $operation.Value -Force | Out-Null
        }
        else {
            Remove-ItemProperty -LiteralPath $operation.Path -Name $operation.Name -ErrorAction SilentlyContinue
        }
    }
    foreach ($operation in $operations) {
        $property = (Get-ItemProperty -LiteralPath $operation.Path).PSObject.Properties[$operation.Name]
        if ($operation.Action -eq 'Set' -and ($null -eq $property -or [int64]$property.Value -ne [int64]$operation.Value)) {
            throw "Priority verification failed for $($operation.Path) $($operation.Name)."
        }
        if ($operation.Action -eq 'Remove' -and $null -ne $property) { throw "Priority removal verification failed for $($operation.Path) $($operation.Name)." }
    }
    @($operations)
}

function Resolve-AudioProfileDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $resolved = @{}
    foreach ($device in @($Profile.devices)) {
        $key = [string]$device.key
        $match = $device.match
        $required = -not (Test-AudioObjectProperty -Object $device -Name 'required') -or [bool]$device.required
        $flowCandidates = @($Inventory | Where-Object { Test-AudioIdentityValueEqual -Actual $_.Flow -Expected $match.flow })
        $exact = @()
        if (Test-AudioObjectProperty -Object $match -Name 'endpointId') {
            $exact = @($flowCandidates | Where-Object {
                (Test-AudioIdentityValueEqual -Actual $_.EndpointId -Expected $match.endpointId) -and
                (Test-AudioEndpointFingerprint -Endpoint $_ -Match $match)
            })
        }

        if ($exact.Count -eq 1) {
            $resolved[$key] = $exact[0]
            continue
        }
        if ($exact.Count -gt 1) { throw "Device '$key' matched $($exact.Count) endpoints by endpointId." }

        $stableId = Get-AudioObjectProperty -Object $match -Name 'stableId'
        if (-not [string]::IsNullOrWhiteSpace([string]$stableId)) {
            $stableIdMatches = @($flowCandidates | Where-Object {
                [string]::Equals(
                    [string](Get-AudioObjectProperty -Object $_ -Name 'StableId'),
                    [string]$stableId,
                    [StringComparison]::Ordinal
                )
            })
            if ($stableIdMatches.Count -eq 1) {
                $resolved[$key] = $stableIdMatches[0]
                continue
            }
            if ($stableIdMatches.Count -gt 1) { throw "Device '$key' matched $($stableIdMatches.Count) endpoints by stableId." }
        }

        $strongCount = Get-AudioStrongFingerprintCount -Match $match
        $stable = @(if ($strongCount -ge 2) {
            $flowCandidates | Where-Object { Test-AudioEndpointFingerprint -Endpoint $_ -Match $match -IgnoreEndpointId -IgnoreStableId }
        })

        if ($stable.Count -eq 1) {
            $resolved[$key] = $stable[0]
        }
        elseif ($stable.Count -gt 1) {
            throw "Device '$key' matched $($stable.Count) endpoints by stable identity."
        }
        elseif ($required) {
            throw "Required device '$key' did not match any endpoint."
        }
        else {
            $resolved[$key] = $null
        }
    }
    $claimedEndpoints = @{}
    foreach ($pair in $resolved.GetEnumerator()) {
        if ($null -eq $pair.Value) { continue }
        $identity = "$($pair.Value.Flow)/$($pair.Value.EndpointId)"
        if ($claimedEndpoints.ContainsKey($identity)) {
            throw "Device '$($pair.Key)' and device '$($claimedEndpoints[$identity])' resolve to the same endpoint '$identity'."
        }
        $claimedEndpoints[$identity] = [string]$pair.Key
    }
    $resolved
}

function Get-AudioPriorityAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][hashtable]$ResolvedDevices,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $assignments = [Collections.Generic.List[object]]::new()
    $priority = Get-AudioObjectProperty -Object $Profile -Name 'priority'
    if ($null -eq $priority) { return @() }
    $profileDevices = @{}
    foreach ($device in @($Profile.devices)) { $profileDevices[[string]$device.key] = $device }

    foreach ($flow in @('render', 'capture')) {
        $flowPriority = Get-AudioObjectProperty -Object $priority -Name $flow
        if ($null -eq $flowPriority) { continue }

        $eligibleEndpoints = @($Inventory | Where-Object {
            (Test-AudioIdentityValueEqual -Actual $_.Flow -Expected $flow) -and
            -not [bool](Get-AudioObjectProperty -Object $_ -Name 'NeverSetAsDefault')
        })
        $eligibleKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($pair in $ResolvedDevices.GetEnumerator()) {
            if ($null -ne $pair.Value -and @($eligibleEndpoints | Where-Object {
                Test-AudioIdentityValueEqual -Actual $_.EndpointId -Expected $pair.Value.EndpointId
            }).Count -eq 1) {
                [void]$eligibleKeys.Add([string]$pair.Key)
            }
        }

        $allRoles = Get-AudioObjectProperty -Object $flowPriority -Name 'allRoles'
        if ($null -eq $allRoles) { throw "Flow '$flow' requires an allRoles priority list." }
        $baseOrder = @(Get-AudioObjectProperty -Object $allRoles -Name 'leastToMostPreferred')
        $roleOverrides = Get-AudioObjectProperty -Object $flowPriority -Name 'roles'

        foreach ($role in @('console', 'multimedia', 'communications')) {
            $order = $baseOrder
            $override = Get-AudioObjectProperty -Object $roleOverrides -Name $role
            if ($null -ne $override) { $order = @(Get-AudioObjectProperty -Object $override -Name 'leastToMostPreferred') }

            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $includedEligible = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $order) {
                if (-not $seen.Add([string]$key)) { throw "Flow '$flow' role '$role' contains duplicate device key '$key'." }
                if (-not $profileDevices.ContainsKey([string]$key)) { throw "Flow '$flow' role '$role' references unknown device '$key'." }
                $resolvedEndpoint = $ResolvedDevices[[string]$key]
                if ($null -eq $resolvedEndpoint) {
                    $profileDevice = $profileDevices[[string]$key]
                    $required = -not (Test-AudioObjectProperty -Object $profileDevice -Name 'required') -or [bool]$profileDevice.required
                    if ($required) { throw "Flow '$flow' role '$role' references missing required device '$key'." }
                    continue
                }
                if (-not $eligibleKeys.Contains([string]$key)) { throw "Flow '$flow' role '$role' references ineligible device '$key'." }
                [void]$includedEligible.Add([string]$key)
            }
            if ($includedEligible.Count -ne $eligibleEndpoints.Count) {
                throw "Flow '$flow' role '$role' requires a complete priority list of $($eligibleEndpoints.Count) registered endpoints; got $($includedEligible.Count)."
            }

            for ($index = 0; $index -lt $order.Count; $index++) {
                $key = [string]$order[$index]
                if ($null -eq $ResolvedDevices[$key]) { continue }
                $assignments.Add([pscustomobject]@{
                    Flow = $flow
                    Role = $role
                    RoleIndex = @('console', 'multimedia', 'communications').IndexOf($role)
                    Key = $key
                    EndpointId = $ResolvedDevices[$key].EndpointId
                    Level = [int64](1000 + $index)
                })
            }
        }
    }
    @($assignments)
}

Export-ModuleMember -Function Import-AudioProfile,Import-AudioBackup,Resolve-AudioProfileDevices,Get-AudioPriorityAssignments,ConvertFrom-AudioWaveFormat,ConvertTo-AudioWaveFormatBytes,Get-WindowsAudioInventory,Initialize-AudioInterop,Get-WindowsAudioEndpointVolume,Get-WindowsAudioDefaultEndpoint,Set-WindowsAudioEndpointVolume,Set-WindowsAudioDefaultEndpoint,Set-WindowsAudioEndpointVisibility,Set-WindowsAudioEndpointProperties,Get-AudioMachineHash,New-AudioProfileDocument,Get-AudioIconSourceFile,Test-AudioProfileState,New-AudioBackupDocument,Get-AudioBackupDeviceRestoreArguments,Get-AudioBackupDifferences,Get-AudioProfileDifferences,Get-AudioPriorityRegistryOperations,Set-AudioPriorityRegistryValues
