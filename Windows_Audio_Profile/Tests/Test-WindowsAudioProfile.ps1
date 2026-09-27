[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utilityRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $utilityRoot 'WindowsAudioProfile.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsAudioProfile-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Expected error matching '$Pattern', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Message Expected an exception."
}

function Write-TestProfile {
    param([Parameter(Mandatory)][hashtable]$Document)
    $path = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $path
}

function Invoke-JsonScript {
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments)
    $stderr = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.err')
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2> $stderr
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $rawError = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
    $errorText = if ($null -eq $rawError) { '' } else { [string]$rawError }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string](@($output) -join "`n")
        Error = $errorText.Trim()
    }
}

function New-ValidProfile {
    @{
        schemaVersion = 1
        profile = @{ name = 'Test profile' }
        devices = @(
            @{
                key = 'speakers'
                required = $true
                match = @{
                    flow = 'render'
                    endpointId = '{11111111-1111-1111-1111-111111111111}'
                    containerId = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'
                    deviceInstanceId = 'USB\VID_0001&PID_0001\A'
                }
                settings = @{
                    name = 'Speakers'
                    enabled = $true
                    volume = @{ percent = 50; muted = $false }
                    format = @{ channels = 2; sampleRateHz = 48000; bitsPerSample = 24 }
                }
            },
            @{
                key = 'headphones'
                required = $true
                match = @{
                    flow = 'render'
                    endpointId = '{22222222-2222-2222-2222-222222222222}'
                    containerId = '{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}'
                    deviceInstanceId = 'BTHENUM\DEV_001122334455\1'
                }
                settings = @{ volume = @{ decibels = 0.0 } }
            }
        )
        priority = @{
            render = @{
                allRoles = @{ leastToMostPreferred = @('speakers', 'headphones') }
                roles = @{ communications = @{ leastToMostPreferred = @('headphones', 'speakers') } }
            }
        }
    }
}

function New-ValidBackup {
    @{
        version = 1
        createdAtUtc = '2026-01-01T00:00:00.0000000Z'
        machineIdSha256 = Get-AudioMachineHash
        sourceProfile = 'C:\Audio\profile.json'
        priorityIncluded = $false
        priorityFlows = @()
        priorityEndpoints = @()
        devices = @(
            @{
                key='speakers'; flow='render'; endpointId='{11111111-1111-1111-1111-111111111111}'
                fullEndpointId='{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}'
                name='Speakers'; icon=''; enabled=$true; format=$null; volume=$null
                levels=@{ console=1000; multimedia=1000; communications=1000 }
                touched=@('enabled')
            }
        )
        defaults = @()
    }
}

function New-ValidPriorityBackup {
    $backup = New-ValidBackup
    $backup.priorityIncluded = $true
    $backup.priorityFlows = @('render')
    $backup.priorityEndpoints = @(@{ flow='render'; endpointId='{11111111-1111-1111-1111-111111111111}' })
    $backup.defaults = @(
        @{ flow='render'; role='console'; endpointId='{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}' },
        @{ flow='render'; role='multimedia'; endpointId='{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}' },
        @{ flow='render'; role='communications'; endpointId='{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}' }
    )
    $backup
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Import-Module $modulePath -Force

    $validPath = Write-TestProfile -Document (New-ValidProfile)
    $profile = Import-AudioProfile -Path $validPath
    Assert-True ($profile.schemaVersion -eq 1) 'A valid version 1 profile must load.'
    Assert-True (@($profile.devices).Count -eq 2) 'A valid profile must retain both devices.'
    Assert-Throws { Import-AudioProfile -Path $validPath -ExpectedSha256 ('0' * 64) } 'hash verification failed' 'Apply input must be bound to the pre-elevation profile hash.'

    $invalidVolume = New-ValidProfile
    $invalidVolume.devices[0].settings.volume = @{ percent = 50; decibels = -6.0 }
    $invalidVolumePath = Write-TestProfile -Document $invalidVolume
    Assert-Throws { Import-AudioProfile -Path $invalidVolumePath } 'either percent or decibels' 'Volume must reject conflicting units.'

    $duplicateKeys = New-ValidProfile
    $duplicateKeys.devices[1].key = 'SPEAKERS'
    $duplicateKeysPath = Write-TestProfile -Document $duplicateKeys
    Assert-Throws { Import-AudioProfile -Path $duplicateKeysPath } 'Duplicate device key' 'Device keys must be unique without regard to case.'

    $unknownSetting = New-ValidProfile
    $unknownSetting.devices[0].settings.volumee = @{ percent = 25 }
    $unknownSettingPath = Write-TestProfile -Document $unknownSetting
    Assert-Throws { Import-AudioProfile -Path $unknownSettingPath } 'Unknown property.*volumee' 'Unknown profile fields must fail instead of being ignored.'

    $emptyDevices = New-ValidProfile
    $emptyDevices.devices = @()
    $emptyDevicesPath = Write-TestProfile -Document $emptyDevices
    Assert-Throws { Import-AudioProfile -Path $emptyDevicesPath } 'at least one device' 'A profile must contain at least one device.'

    $invalidBinding = New-ValidProfile
    $invalidBinding.target = @{ binding = 'loose' }
    $invalidBindingPath = Write-TestProfile -Document $invalidBinding
    Assert-Throws { Import-AudioProfile -Path $invalidBindingPath } 'target.binding' 'Machine binding must reject unsupported modes.'

    $missingStrictHash = New-ValidProfile
    $missingStrictHash.target = @{ binding = 'strict' }
    $missingStrictHashPath = Write-TestProfile -Document $missingStrictHash
    Assert-Throws { Import-AudioProfile -Path $missingStrictHashPath } 'machineIdSha256.*required' 'Strict machine binding must require an explicit machine hash.'

    $invalidFormat = New-ValidProfile
    $invalidFormat.devices[0].settings.format.sampleRateHz = 0
    $invalidFormatPath = Write-TestProfile -Document $invalidFormat
    Assert-Throws { Import-AudioProfile -Path $invalidFormatPath } 'positive JSON integer' 'Format values must be validated before Apply.'

    $stringBoolean = New-ValidProfile
    $stringBoolean.devices[0].required = 'false'
    $stringBoolean.devices[0].settings.enabled = 'false'
    $stringBoolean.devices[0].settings.volume.muted = 'false'
    $stringBooleanPath = Write-TestProfile -Document $stringBoolean
    Assert-Throws { Import-AudioProfile -Path $stringBooleanPath } 'required.*Boolean' 'String booleans must be rejected before planning.'

    $stringEnabled = New-ValidProfile
    $stringEnabled.devices[0].settings.enabled = 'false'
    $stringEnabledPath = Write-TestProfile -Document $stringEnabled
    Assert-Throws { Import-AudioProfile -Path $stringEnabledPath } 'enabled.*Boolean' 'String enabled values must be rejected.'

    $stringMuted = New-ValidProfile
    $stringMuted.devices[0].settings.volume.muted = 'false'
    $stringMutedPath = Write-TestProfile -Document $stringMuted
    Assert-Throws { Import-AudioProfile -Path $stringMutedPath } 'muted.*Boolean' 'String muted values must be rejected.'

    $stringPercent = New-ValidProfile
    $stringPercent.devices[0].settings.volume.percent = '50'
    $stringPercentPath = Write-TestProfile -Document $stringPercent
    Assert-Throws { Import-AudioProfile -Path $stringPercentPath } 'percent.*number' 'String volume numbers must be rejected.'

    $emptyVolume = New-ValidProfile
    $emptyVolume.devices[0].settings.volume = @{}
    $emptyVolumePath = Write-TestProfile -Document $emptyVolume
    Assert-Throws { Import-AudioProfile -Path $emptyVolumePath } 'volume.*at least one' 'An empty volume patch must be rejected.'

    $invalidEndpointId = New-ValidProfile
    $invalidEndpointId.devices[0].match.endpointId = 'not-a-guid'
    $invalidEndpointIdPath = Write-TestProfile -Document $invalidEndpointId
    Assert-Throws { Import-AudioProfile -Path $invalidEndpointIdPath } 'endpointId.*GUID' 'Invalid endpoint IDs must be rejected during import.'

    $scalarHardwareIds = New-ValidProfile
    $scalarHardwareIds.devices[0].match.hardwareIds = 'USB\VID_0001&PID_0001'
    $scalarHardwareIdsPath = Write-TestProfile -Document $scalarHardwareIds
    Assert-Throws { Import-AudioProfile -Path $scalarHardwareIdsPath } 'hardwareIds.*array' 'hardwareIds must remain a JSON array.'

    $scalarPriority = New-ValidProfile
    $scalarPriority.priority.render.allRoles.leastToMostPreferred = 'speakers'
    $scalarPriorityPath = Write-TestProfile -Document $scalarPriority
    Assert-Throws { Import-AudioProfile -Path $scalarPriorityPath } 'leastToMostPreferred.*array' 'Priority order must remain a JSON array.'

    $validBackupPath = Write-TestProfile -Document (New-ValidBackup)
    $validBackup = Import-AudioBackup -Path $validBackupPath
    Assert-True ($validBackup.version -eq 1) 'A valid version 1 backup must load.'
    $stringBackupBoolean = New-ValidBackup
    $stringBackupBoolean.devices[0].enabled = 'false'
    $stringBackupBooleanPath = Write-TestProfile -Document $stringBackupBoolean
    Assert-Throws { Import-AudioBackup -Path $stringBackupBooleanPath } 'enabled.*Boolean' 'Backup string booleans must be rejected before Undo.'
    $stringPriorityIncluded = New-ValidBackup
    $stringPriorityIncluded.priorityIncluded = 'false'
    $stringPriorityIncludedPath = Write-TestProfile -Document $stringPriorityIncluded
    Assert-Throws { Import-AudioBackup -Path $stringPriorityIncludedPath } 'priorityIncluded.*Boolean' 'Backup priorityIncluded must remain Boolean.'
    $scalarTouched = New-ValidBackup
    $scalarTouched.devices[0].touched = 'enabled'
    $scalarTouchedPath = Write-TestProfile -Document $scalarTouched
    Assert-Throws { Import-AudioBackup -Path $scalarTouchedPath } 'touched.*array' 'Backup touched must remain a JSON array.'
    Assert-Throws { Import-AudioBackup -Path $validBackupPath -ExpectedSha256 ('0' * 64) } 'hash verification failed' 'Undo input must be bound to the pre-elevation backup hash.'
    $emptyPriorityEndpoints = New-ValidPriorityBackup
    $emptyPriorityEndpoints.priorityEndpoints = @()
    $emptyPriorityEndpointsPath = Write-TestProfile -Document $emptyPriorityEndpoints
    Assert-Throws { Import-AudioBackup -Path $emptyPriorityEndpointsPath } 'priorityEndpoints.*not be empty' 'Priority restore scope must never fall back from an empty endpoint list to every device.'
    $orphanPriorityEndpoint = New-ValidPriorityBackup
    $orphanPriorityEndpoint.priorityEndpoints[0].endpointId = '{22222222-2222-2222-2222-222222222222}'
    foreach ($default in $orphanPriorityEndpoint.defaults) { $default.endpointId = '{0.0.0.00000000}.{22222222-2222-2222-2222-222222222222}' }
    $orphanPriorityEndpointPath = Write-TestProfile -Document $orphanPriorityEndpoint
    Assert-Throws { Import-AudioBackup -Path $orphanPriorityEndpointPath } 'no matching device snapshot' 'Every priority endpoint must have one exact device snapshot.'
    $crossFlowDefault = New-ValidPriorityBackup
    $crossFlowDefault.defaults[0].endpointId = '{0.0.1.00000000}.{11111111-1111-1111-1111-111111111111}'
    $crossFlowDefaultPath = Write-TestProfile -Document $crossFlowDefault
    Assert-Throws { Import-AudioBackup -Path $crossFlowDefaultPath } 'for its flow' 'A default endpoint ID must encode the declared flow.'

    $inventory = @(
        [pscustomobject]@{
            Flow = 'render'; EndpointId = '{11111111-1111-1111-1111-111111111111}'
            ContainerId = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'; DeviceInstanceId = 'USB\VID_0001&PID_0001\A'
            HardwareIds = @('USB\VID_0001&PID_0001'); DriverProvider = 'Microsoft'; NeverSetAsDefault = $false
        },
        [pscustomobject]@{
            Flow = 'render'; EndpointId = '{99999999-9999-9999-9999-999999999999}'
            ContainerId = '{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}'; DeviceInstanceId = 'BTHENUM\DEV_001122334455\1'
            HardwareIds = @('BTHENUM\DEV_001122334455'); DriverProvider = 'Alternative A2DP'; NeverSetAsDefault = $false
        }
    )

    $resolved = Resolve-AudioProfileDevices -Profile $profile -Inventory $inventory
    Assert-True ($resolved['speakers'].EndpointId -eq '{11111111-1111-1111-1111-111111111111}') 'Exact endpoint identity must resolve.'
    Assert-True ($resolved['headphones'].EndpointId -eq '{99999999-9999-9999-9999-999999999999}') 'Stable identity must survive an endpoint ID change.'

    $duplicateEndpointProfile = New-ValidProfile
    $duplicateEndpointProfile.devices[1].match = @{
        flow = 'render'
        endpointId = '{11111111-1111-1111-1111-111111111111}'
        containerId = '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'
        deviceInstanceId = 'USB\VID_0001&PID_0001\A'
    }
    $duplicateEndpointPath = Write-TestProfile -Document $duplicateEndpointProfile
    $duplicateEndpointDocument = Import-AudioProfile -Path $duplicateEndpointPath
    Assert-Throws { Resolve-AudioProfileDevices -Profile $duplicateEndpointDocument -Inventory $inventory } 'same endpoint' 'Two profile keys must not resolve to the same endpoint.'

    $ambiguousInventory = @($inventory) + [pscustomobject]@{
        Flow = 'render'; EndpointId = '{88888888-8888-8888-8888-888888888888}'
        ContainerId = '{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}'; DeviceInstanceId = 'BTHENUM\DEV_001122334455\1'
        HardwareIds = @('BTHENUM\DEV_001122334455'); DriverProvider = 'Alternative A2DP'; NeverSetAsDefault = $false
    }
    Assert-Throws { Resolve-AudioProfileDevices -Profile $profile -Inventory $ambiguousInventory } 'matched 2 endpoints' 'Ambiguous stable identity must fail closed.'

    $missingOptional = New-ValidProfile
    $missingOptional.devices[1].required = $false
    $missingOptionalPath = Write-TestProfile -Document $missingOptional
    $optionalProfile = Import-AudioProfile -Path $missingOptionalPath
    $optionalResolved = Resolve-AudioProfileDevices -Profile $optionalProfile -Inventory @($inventory[0])
    Assert-True ($optionalResolved['headphones'] -eq $null) 'A missing optional endpoint must remain unresolved without failing.'
    $optionalAssignments = @(Get-AudioPriorityAssignments -Profile $optionalProfile -ResolvedDevices $optionalResolved -Inventory @($inventory[0]))
    Assert-True ($optionalAssignments.Count -eq 3) 'A missing optional endpoint must be skipped in priority writes for all three roles.'

    $assignments = Get-AudioPriorityAssignments -Profile $profile -ResolvedDevices $resolved -Inventory $inventory
    Assert-True ($assignments.Count -eq 6) 'Two devices across three roles must produce six assignments.'
    $consoleHeadphones = @($assignments | Where-Object { $_.Role -eq 'console' -and $_.Key -eq 'headphones' })[0]
    $communicationsSpeakers = @($assignments | Where-Object { $_.Role -eq 'communications' -and $_.Key -eq 'speakers' })[0]
    Assert-True ($consoleHeadphones.Level -gt 1000) 'Later devices must receive a higher default priority.'
    Assert-True ($communicationsSpeakers.Level -gt 1000) 'A role override must replace the all-roles order.'

    $priorityOnlyProfile = [pscustomobject]@{
        devices=@($profile.devices | ForEach-Object { [pscustomobject]@{ key=$_.key; required=$_.required; match=$_.match } })
        priority=$profile.priority
    }
    $priorityInventory = @(
        [pscustomobject]@{
            Flow='render'; EndpointId='{11111111-1111-1111-1111-111111111111}'; FullEndpointId='{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}'
            Active=$true; NeverSetAsDefault=$false; Levels=[pscustomobject]@{ console=1000; multimedia=1000; communications=1001 }
        },
        [pscustomobject]@{
            Flow='render'; EndpointId='{99999999-9999-9999-9999-999999999999}'; FullEndpointId='{0.0.0.00000000}.{99999999-9999-9999-9999-999999999999}'
            Active=$true; NeverSetAsDefault=$false; Levels=[pscustomobject]@{ console=1001; multimedia=1001; communications=1000 }
        }
    )
    $wrongDefaults = @{
        'render/console'=$priorityInventory[0].FullEndpointId
        'render/multimedia'=$priorityInventory[1].FullEndpointId
        'render/communications'=$priorityInventory[0].FullEndpointId
    }
    $defaultDifferences = @(Get-AudioProfileDifferences -Profile $priorityOnlyProfile -ResolvedDevices $resolved -Inventory $priorityInventory -DefaultEndpoints $wrongDefaults)
    Assert-True (@($defaultDifferences | Where-Object { $_.property -eq 'default.console' }).Count -eq 1) 'Profile comparison must detect an incorrect effective default endpoint even when priority levels match.'
    $wrongDefaults['render/console'] = $priorityInventory[1].FullEndpointId
    Assert-True (@(Get-AudioProfileDifferences -Profile $priorityOnlyProfile -ResolvedDevices $resolved -Inventory $priorityInventory -DefaultEndpoints $wrongDefaults).Count -eq 0) 'Profile comparison must accept matching priority levels and effective defaults.'

    $incomplete = New-ValidProfile
    $incomplete.priority.render.allRoles.leastToMostPreferred = @('headphones')
    $incompletePath = Write-TestProfile -Document $incomplete
    $incompleteProfile = Import-AudioProfile -Path $incompletePath
    Assert-Throws { Get-AudioPriorityAssignments -Profile $incompleteProfile -ResolvedDevices $resolved -Inventory $inventory } 'complete priority list' 'Priority lists must cover every eligible endpoint.'

    $inactiveEndpoint = [pscustomobject]@{
        Flow='render'; EndpointId='{11111111-1111-1111-1111-111111111111}'; Active=$false
        Name='Speakers'; Icon='C:\Windows\System32\mmres.dll,-1'; Enabled=$false; Format=$null
        NeverSetAsDefault=$false; Levels=[pscustomobject]@{ console=1; multimedia=1; communications=1 }
    }
    $inactiveVolumeProfile = [pscustomobject]@{
        devices=@([pscustomobject]@{ key='speakers'; settings=[pscustomobject]@{ volume=[pscustomobject]@{ percent=73 } } })
    }
    $inactiveVolumeDifferences = @(Get-AudioProfileDifferences -Profile $inactiveVolumeProfile -ResolvedDevices @{ speakers=$inactiveEndpoint } -Inventory @($inactiveEndpoint))
    Assert-True (@($inactiveVolumeDifferences | Where-Object { $_.property -eq 'volume' }).Count -eq 1) 'Inactive endpoint volume must require Apply instead of becoming a no-op.'
    $verifiedInactiveVolumeDifferences = @(Get-AudioProfileDifferences -Profile $inactiveVolumeProfile -ResolvedDevices @{ speakers=$inactiveEndpoint } -Inventory @($inactiveEndpoint) -VerifiedVolumeKeys @('speakers'))
    Assert-True ($verifiedInactiveVolumeDifferences.Count -eq 0) 'Post-apply comparison must accept volume verified before a requested disable.'

    $pcmStereo24Bit48Khz = [byte[]](
        0xFE,0xFF, 0x02,0x00, 0x80,0xBB,0x00,0x00,
        0x00,0x65,0x04,0x00, 0x06,0x00, 0x18,0x00,
        0x16,0x00, 0x18,0x00, 0x03,0x00,0x00,0x00,
        0x01,0x00,0x00,0x00, 0x00,0x00, 0x10,0x00,
        0x80,0x00,0x00,0xAA, 0x00,0x38,0x9B,0x71
    )
    $format = ConvertFrom-AudioWaveFormat -Bytes $pcmStereo24Bit48Khz
    Assert-True ($format.channels -eq 2) 'Wave format parser must read the channel count.'
    Assert-True ($format.sampleRateHz -eq 48000) 'Wave format parser must read the sample rate.'
    Assert-True ($format.bitsPerSample -eq 24) 'Wave format parser must read the bit depth.'
    Assert-True ($format.encoding -eq 'pcm') 'Wave format parser must identify PCM.'
    Assert-True ($format.channelMask -eq 3) 'Wave format parser must preserve the channel mask.'
    $rebuiltFormat = ConvertTo-AudioWaveFormatBytes -Format $format
    Assert-True ([Convert]::ToBase64String($rebuiltFormat) -eq [Convert]::ToBase64String($pcmStereo24Bit48Khz)) 'Wave format serialization must preserve the exact semantic format.'

    $classicPcmStereo16Bit48Khz = [byte[]](
        0x01,0x00, 0x02,0x00, 0x80,0xBB,0x00,0x00,
        0x00,0xEE,0x02,0x00, 0x04,0x00, 0x10,0x00,
        0x00,0x00
    )
    $classicFormat = ConvertFrom-AudioWaveFormat -Bytes $classicPcmStereo16Bit48Khz
    Assert-True ($classicFormat.extensible -eq $false) 'Classic WAVEFORMATEX must remain non-extensible.'
    $rebuiltClassicFormat = ConvertTo-AudioWaveFormatBytes -Format $classicFormat
    Assert-True ([Convert]::ToBase64String($rebuiltClassicFormat) -eq [Convert]::ToBase64String($classicPcmStereo16Bit48Khz)) 'Classic WAVEFORMATEX serialization must preserve its structure.'

    $noIconEndpoint = [pscustomobject]@{
        Flow='render'; EndpointId='{33333333-3333-3333-3333-333333333333}'; FullEndpointId='{0.0.0.00000000}.{33333333-3333-3333-3333-333333333333}'; Name='No icon'
        ContainerId='{cccccccc-cccc-cccc-cccc-cccccccccccc}'; DeviceInstanceId='ROOT\NOICON\1'
        HardwareIds=@(); DriverIdentity='test'; Icon=''; Format=$null; Enabled=$true; Active=$false
        NeverSetAsDefault=$true; Levels=[pscustomobject]@{ console=$null; multimedia=$null; communications=$null }
    }
    $noIconProfile = New-AudioProfileDocument -Inventory @($noIconEndpoint)
    Assert-True (-not $noIconProfile.devices[0].settings.Contains('icon')) 'Export must omit an absent icon instead of violating its schema.'
    $unrestorableIconProfile = [pscustomobject]@{ devices=@([pscustomobject]@{ key='no-icon'; settings=[pscustomobject]@{ icon='C:\Windows\System32\mmres.dll,-1' } }) }
    Assert-Throws { New-AudioBackupDocument -Profile $unrestorableIconProfile -ResolvedDevices @{ 'no-icon'=$noIconEndpoint } -Inventory @($noIconEndpoint) } 'reversible backup.*icon' 'Apply must stop before changing an icon whose absent original value cannot be restored.'

    $liveInventory = @(Get-WindowsAudioInventory)
    Assert-True ($liveInventory.Count -gt 0) 'Windows audio inventory must contain at least one endpoint.'
    $firstLiveEndpoint = $liveInventory[0]
    Assert-True ($firstLiveEndpoint.Flow -in @('render', 'capture')) 'Every live endpoint must have a supported flow.'
    Assert-True ($firstLiveEndpoint.EndpointId -match '^\{[0-9a-f-]{36}\}$') 'Every live endpoint must expose a GUID endpoint ID.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstLiveEndpoint.Name)) 'Every live endpoint must expose a display name.'
    $uniqueLiveIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($endpoint in $liveInventory) {
        Assert-True ($uniqueLiveIds.Add("$($endpoint.Flow)/$($endpoint.EndpointId)")) 'Flow and endpoint ID pairs must be unique.'
    }

    Initialize-AudioInterop -SourcePath (Join-Path $utilityRoot 'CoreAudio.cs')
    $tokenRunnerParameters = [DSNTools.WindowsAudioProfile.TokenRunner].GetMethod('RunFromProcessToken').GetParameters()
    Assert-True ($tokenRunnerParameters.Count -eq 5 -and $tokenRunnerParameters[4].Name -eq 'timeoutMilliseconds') 'TrustedInstaller child execution must have an explicit finite timeout.'
    $activeEndpoints = @($liveInventory | Where-Object { $_.Active })
    $activeEndpoint = if ($activeEndpoints.Count -gt 0) { $activeEndpoints[0] } else { $null }
    $liveVolume = $null
    if ($null -ne $activeEndpoint) {
        $liveVolume = Get-WindowsAudioEndpointVolume -Endpoint $activeEndpoint
        Assert-True ($liveVolume.percent -ge 0 -and $liveVolume.percent -le 100) 'Active endpoint volume must be normalized to 0-100 percent.'
        Assert-True ($liveVolume.decibels -ge $liveVolume.minimumDecibels -and $liveVolume.decibels -le $liveVolume.maximumDecibels) 'Active endpoint dB value must be inside its reported range.'
        Assert-True ($liveVolume.muted -is [bool]) 'Active endpoint mute state must be Boolean.'

        foreach ($role in @('console', 'multimedia', 'communications')) {
            $defaultId = Get-WindowsAudioDefaultEndpoint -Flow $activeEndpoint.Flow -Role $role
            Assert-True ($null -eq $defaultId -or $defaultId -match '^\{0\.0\.[01]\.00000000\}\.\{[0-9a-f-]{36}\}$') 'Default endpoint IDs must use the MMDevice ID format.'
        }
    }

    $exportScript = Join-Path $utilityRoot 'Export-AudioProfile.ps1'
    $testScript = Join-Path $utilityRoot 'Test-AudioProfile.ps1'
    $exportedProfilePath = Join-Path $testRoot 'exported-profile.json'
    $exportResult = Invoke-JsonScript -Script $exportScript -Arguments @('-OutputPath', $exportedProfilePath, '-Json')
    Assert-True ($exportResult.ExitCode -eq 0) "Profile export must succeed: $($exportResult.Error)"
    Assert-True (Test-Path -LiteralPath $exportedProfilePath -PathType Leaf) 'Profile export must create the requested JSON file.'
    $exportedProfile = Get-Content -Raw -LiteralPath $exportedProfilePath | ConvertFrom-Json
    Assert-True (@($exportedProfile.devices).Count -eq $liveInventory.Count) 'Profile export must include all registered endpoints.'
    Assert-True ($exportedProfile.target.binding -eq 'strict') 'Profile export must bind to the source computer by default.'

    $testResult = Invoke-JsonScript -Script $testScript -Arguments @('-ProfilePath', $exportedProfilePath, '-Json')
    Assert-True ($testResult.ExitCode -eq 0) "A freshly exported profile must validate on the same machine: $($testResult.Error)"
    $testReport = $testResult.Output | ConvertFrom-Json
    Assert-True ($testReport.valid -eq $true) 'A freshly exported profile report must be valid.'
    Assert-True ($testReport.matchedDevices -eq $liveInventory.Count) 'Profile test must resolve every exported endpoint.'

    $applyScript = Join-Path $utilityRoot 'Apply-AudioProfile.ps1'
    $applyCommand = Get-Command -Name $applyScript
    $undoCommand = Get-Command -Name (Join-Path $utilityRoot 'Undo-AudioProfile.ps1')
    Assert-True ($applyCommand.Parameters.ContainsKey('WhatIf') -and -not $applyCommand.Parameters.ContainsKey('Confirm')) 'Apply must expose an explicit WhatIf preview without a fake Confirm contract.'
    Assert-True ($undoCommand.Parameters.ContainsKey('WhatIf') -and -not $undoCommand.Parameters.ContainsKey('Confirm')) 'Undo must expose an explicit WhatIf preview without a fake Confirm contract.'
    $applyPreview = Invoke-JsonScript -Script $applyScript -Arguments @('-ProfilePath', $exportedProfilePath, '-ApplyMode', 'Strict', '-WhatIf', '-Json')
    Assert-True ($applyPreview.ExitCode -eq 0) "Apply -WhatIf must succeed without elevation: $($applyPreview.Error)"
    $applyPlan = $applyPreview.Output | ConvertFrom-Json
    Assert-True ($applyPlan.whatIf -eq $true) 'Apply preview must identify itself as WhatIf.'
    Assert-True ($applyPlan.devices -eq $liveInventory.Count) 'Apply preview must include every matched exported endpoint.'
    Assert-True ($null -eq $applyPlan.backup) 'Apply preview must not create a backup.'

    $freshProfile = Import-AudioProfile -Path $exportedProfilePath
    $freshInventory = @(Get-WindowsAudioInventory)
    $freshResolved = Resolve-AudioProfileDevices -Profile $freshProfile -Inventory $freshInventory
    $freshPriorityFlows = @(@('render','capture') | Where-Object { $null -ne $freshProfile.priority.PSObject.Properties[$_] })
    $canSnapshotLiveDefaults = $true
    foreach ($flow in $freshPriorityFlows) {
        foreach ($role in @('console','multimedia','communications')) {
            try { $defaultId = Get-WindowsAudioDefaultEndpoint -Flow $flow -Role $role }
            catch { $defaultId = $null }
            if ([string]::IsNullOrWhiteSpace([string]$defaultId)) { $canSnapshotLiveDefaults = $false }
        }
    }
    if ($canSnapshotLiveDefaults) {
        $backupDocument = New-AudioBackupDocument -Profile $freshProfile -ResolvedDevices $freshResolved -Inventory $freshInventory
    }
    else {
        $backupProfileWithoutPriority = Import-AudioProfile -Path $exportedProfilePath
        [void]$backupProfileWithoutPriority.PSObject.Properties.Remove('priority')
        $backupDocument = New-AudioBackupDocument -Profile $backupProfileWithoutPriority -ResolvedDevices $freshResolved -Inventory $freshInventory
    }
    Assert-True ($backupDocument.version -eq 1) 'Audio backup format must be versioned.'
    Assert-True (@($backupDocument.devices).Count -eq $liveInventory.Count) 'Audio backup must capture every matched endpoint.'
    Assert-True (@($backupDocument.defaults).Count -eq (3 * @($backupDocument.priorityFlows).Count)) 'Audio backup must capture three defaults for every requested priority flow.'

    if ($null -ne $activeEndpoint) {
        $muteOnlyProfile = [pscustomobject]@{
            devices=@([pscustomobject]@{
                key='mute-only'
                settings=[pscustomobject]@{ volume=[pscustomobject]@{ muted=[bool]$liveVolume.muted } }
            })
        }
        $muteOnlyBackup = New-AudioBackupDocument -Profile $muteOnlyProfile -ResolvedDevices @{ 'mute-only'=$activeEndpoint } -Inventory $liveInventory
        Assert-True (@($muteOnlyBackup.devices[0].touched) -contains 'volume.muted') 'Backup must track mute independently.'
        Assert-True (@($muteOnlyBackup.devices[0].touched) -notcontains 'volume.level') 'Mute-only patches must not restore the volume level.'
        $muteOnlyRestore = Get-AudioBackupDeviceRestoreArguments -Device $muteOnlyBackup.devices[0]
        Assert-True ($muteOnlyRestore.Volume.ContainsKey('Muted')) 'Mute-only restore must include the saved mute state.'
        Assert-True (-not $muteOnlyRestore.Volume.ContainsKey('Decibels')) 'Mute-only restore must not overwrite a later volume-level change.'
        Assert-True (@($muteOnlyBackup.defaults).Count -eq 0) 'A profile without priority must not snapshot defaults.'
    }

    if ($canSnapshotLiveDefaults -and $freshPriorityFlows.Count -gt 0) {
        $singleFlowProfile = Import-AudioProfile -Path $exportedProfilePath
        $singleFlow = $freshPriorityFlows[0]
        foreach ($otherFlow in @(@('render','capture') | Where-Object { $_ -ne $singleFlow })) { [void]$singleFlowProfile.priority.PSObject.Properties.Remove($otherFlow) }
        $singleFlowResolved = Resolve-AudioProfileDevices -Profile $singleFlowProfile -Inventory $freshInventory
        $singleFlowBackup = New-AudioBackupDocument -Profile $singleFlowProfile -ResolvedDevices $singleFlowResolved -Inventory $freshInventory
        Assert-True (@($singleFlowBackup.priorityFlows).Count -eq 1 -and $singleFlowBackup.priorityFlows[0] -eq $singleFlow) 'Backup must record only the priority flow requested by the profile.'
        Assert-True (@($singleFlowBackup.defaults).Count -eq 3) 'A single-flow priority patch must snapshot only three defaults.'
        $expectedSingleFlowPriorityEndpoints = @($freshInventory | Where-Object { $_.Flow -eq $singleFlow -and -not $_.NeverSetAsDefault }).Count
        Assert-True (@($singleFlowBackup.priorityEndpoints).Count -eq $expectedSingleFlowPriorityEndpoints) 'Backup must record exactly the endpoints whose priority Apply can touch.'
    }

    if ($null -ne $activeEndpoint) {
        $changedBackupEndpoint = [pscustomobject]@{
            Flow=$activeEndpoint.Flow; EndpointId=$activeEndpoint.EndpointId; Name=($activeEndpoint.Name + ' changed')
            Icon=$activeEndpoint.Icon; Enabled=$activeEndpoint.Enabled; Format=$activeEndpoint.Format; Active=$activeEndpoint.Active
            Levels=$activeEndpoint.Levels
        }
        $backupDifferences = @(Get-AudioBackupDifferences -Backup ([pscustomobject]@{
            devices=@([pscustomobject]@{
                key='mute-only'; flow=$activeEndpoint.Flow; endpointId=$activeEndpoint.EndpointId
                name=$activeEndpoint.Name; icon=$activeEndpoint.Icon; enabled=$activeEndpoint.Enabled; format=$activeEndpoint.Format
                volume=$liveVolume; levels=$activeEndpoint.Levels; touched=@('name')
            })
            priorityFlows=@(); defaults=@()
        }) -Inventory @($changedBackupEndpoint))
        Assert-True (@($backupDifferences | Where-Object { $_.property -eq 'name' }).Count -eq 1) 'Undo verification must detect a display-name mismatch.'
    }

    $differences = @(Get-AudioProfileDifferences -Profile $freshProfile -ResolvedDevices $freshResolved -Inventory $freshInventory)
    Assert-True ($differences.Count -eq 0) "A freshly exported profile must match current state; got $($differences.Count) difference(s)."

    $priorityAssignments = @(Get-AudioPriorityAssignments -Profile $freshProfile -ResolvedDevices $freshResolved -Inventory $freshInventory)
    $planAssignments = if ($priorityAssignments.Count -gt 0) {
        @($priorityAssignments | ForEach-Object { [ordered]@{ flow=$_.Flow; endpointId=$_.EndpointId; roleIndex=$_.RoleIndex; hasValue=$true; level=$_.Level } })
    }
    else {
        $endpoint = $freshInventory[0]
        $level = $endpoint.Levels.console
        @([ordered]@{ flow=$endpoint.Flow; endpointId=$endpoint.EndpointId; roleIndex=0; hasValue=($null -ne $level); level=$level })
    }
    $priorityPlanPath = Join-Path $testRoot 'priority-plan.json'
    $priorityPlan = [ordered]@{
        version = 1
        machineIdSha256 = Get-AudioMachineHash
        assignments = @($planAssignments)
    }
    [IO.File]::WriteAllText($priorityPlanPath, ($priorityPlan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $priorityWorker = Join-Path $utilityRoot 'Set-AudioPriority.ps1'
    $priorityPlanSha256 = (Get-FileHash -LiteralPath $priorityPlanPath -Algorithm SHA256).Hash
    $priorityValidation = Invoke-JsonScript -Script $priorityWorker -Arguments @('-Mode', 'Validate', '-PlanPath', $priorityPlanPath, '-PlanSha256', $priorityPlanSha256, '-Json')
    Assert-True ($priorityValidation.ExitCode -eq 0) "Priority worker must accept a valid plan: $($priorityValidation.Error)"
    $priorityValidationReport = $priorityValidation.Output | ConvertFrom-Json
    Assert-True ($priorityValidationReport.assignments -eq $planAssignments.Count) 'Priority worker validation must retain every assignment.'
    $invalidPriorityPlan = Get-Content -Raw -LiteralPath $priorityPlanPath | ConvertFrom-Json
    $invalidPriorityPlan.assignments[0].hasValue = 'false'
    $invalidPriorityPlanPath = Join-Path $testRoot 'invalid-priority-plan.json'
    [IO.File]::WriteAllText($invalidPriorityPlanPath, ($invalidPriorityPlan | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $invalidPriorityValidation = Invoke-JsonScript -Script $priorityWorker -Arguments @('-Mode', 'Validate', '-PlanPath', $invalidPriorityPlanPath, '-Json')
    Assert-True ($invalidPriorityValidation.ExitCode -eq 1 -and $invalidPriorityValidation.Error -match 'hasValue.*Boolean') 'Priority plans must reject string booleans before privileged execution.'

    $testEndpointId = '{aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb}'
    $registryOperations = @(Get-AudioPriorityRegistryOperations -AudioRoot 'HKLM:\Example\Audio' -Assignments @(
        [pscustomobject]@{ flow='render'; endpointId=$testEndpointId; roleIndex=0; hasValue=$true; level=1000 },
        [pscustomobject]@{ flow='render'; endpointId=$testEndpointId; roleIndex=1; hasValue=$false; level=$null }
    ))
    Assert-True ($registryOperations[0].Path -eq "HKLM:\Example\Audio\Render\$testEndpointId") 'Priority planner must target the requested render endpoint.'
    Assert-True ($registryOperations[0].Name -eq 'Level:0' -and $registryOperations[0].Action -eq 'Set' -and $registryOperations[0].Value -eq 1000) 'Priority planner must emit an explicit QWord write.'
    Assert-True ($registryOperations[1].Name -eq 'Level:1' -and $registryOperations[1].Action -eq 'Remove') 'Priority planner must emit removal for a previously absent level.'

    Write-Output 'PASS: validation, matching, priorities, formats, Core Audio reads, Export-Test, Apply preview, backup, comparison, and isolated priority writes'
}
finally {
    Remove-Module WindowsAudioProfile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
