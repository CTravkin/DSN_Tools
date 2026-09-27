[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Validate', 'Controller', 'System', 'TrustedInstaller')][string]$Mode,
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$PlanSha256,
    [string]$BundleSha256,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$errorPath = $null

function Import-PriorityPlan {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedSha256)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actualSha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        if (-not [string]::Equals($actualSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Priority plan hash verification failed.' }
    }
    $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 16777216
    $raw = $serializer.DeserializeObject($json)
    if ($raw -isnot [Collections.IDictionary]) { throw 'Priority plan root must be a JSON object.' }
    foreach ($name in $raw.Keys) { if ([string]$name -notin @('version','machineIdSha256','assignments')) { throw "Unknown property '$name' in priority plan." } }
    $version = $raw['version']
    if ($version -isnot [byte] -and $version -isnot [sbyte] -and $version -isnot [int16] -and $version -isnot [uint16] -and $version -isnot [int32] -and $version -isnot [uint32] -and $version -isnot [int64] -and $version -isnot [uint64]) { throw 'Priority plan version must be a JSON integer.' }
    if ([int64]$version -ne 1) { throw 'Unsupported priority plan version; expected 1.' }
    if ($raw['machineIdSha256'] -isnot [string] -or [string]$raw['machineIdSha256'] -notmatch '^[0-9a-fA-F]{64}$') { throw 'Priority plan machineIdSha256 must contain 64 hexadecimal characters.' }
    if ($raw['assignments'] -isnot [array]) { throw 'Priority plan assignments must be a JSON array.' }
    foreach ($assignment in @($raw['assignments'])) {
        if ($assignment -isnot [Collections.IDictionary]) { throw 'Every priority assignment must be a JSON object.' }
        foreach ($name in $assignment.Keys) { if ([string]$name -notin @('flow','endpointId','roleIndex','hasValue','level')) { throw "Unknown property '$name' in priority assignment." } }
        if ($assignment['flow'] -isnot [string] -or [string]$assignment['flow'] -notin @('render','capture')) { throw 'Priority assignment flow must be render or capture.' }
        if ($assignment['endpointId'] -isnot [string] -or [string]$assignment['endpointId'] -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { throw 'Priority assignment endpointId must be a braced GUID.' }
        $roleIndex = $assignment['roleIndex']
        if ($roleIndex -isnot [byte] -and $roleIndex -isnot [sbyte] -and $roleIndex -isnot [int16] -and $roleIndex -isnot [uint16] -and $roleIndex -isnot [int32] -and $roleIndex -isnot [uint32] -and $roleIndex -isnot [int64] -and $roleIndex -isnot [uint64]) { throw 'Priority assignment roleIndex must be a JSON integer.' }
        if ([int64]$roleIndex -lt 0 -or [int64]$roleIndex -gt 2) { throw 'Priority assignment roleIndex must be between 0 and 2.' }
        if ($assignment['hasValue'] -isnot [bool]) { throw 'Priority assignment hasValue must be a JSON Boolean.' }
        $level = $assignment['level']
        if ([bool]$assignment['hasValue']) {
            if ($level -isnot [byte] -and $level -isnot [sbyte] -and $level -isnot [int16] -and $level -isnot [uint16] -and $level -isnot [int32] -and $level -isnot [uint32] -and $level -isnot [int64] -and $level -isnot [uint64]) { throw 'Priority assignment level must be a JSON integer when hasValue is true.' }
        }
        elseif ($null -ne $level) { throw 'Priority assignment level must be null when hasValue is false.' }
    }
    $plan = $json | ConvertFrom-Json
    Import-Module (Join-Path $PSScriptRoot 'WindowsAudioProfile.psm1') -Force
    if (-not [string]::Equals([string]$plan.machineIdSha256, (Get-AudioMachineHash), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Priority plan belongs to a different Windows installation.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in @($plan.assignments)) {
        if ([string]$assignment.flow -notin @('render', 'capture')) { throw "Invalid priority flow '$($assignment.flow)'." }
        if ([string]$assignment.endpointId -notmatch '^\{[0-9a-fA-F-]{36}\}$') { throw "Invalid endpoint ID '$($assignment.endpointId)'." }
        if ([int]$assignment.roleIndex -lt 0 -or [int]$assignment.roleIndex -gt 2) { throw "Invalid role index '$($assignment.roleIndex)'." }
        $identity = "$($assignment.flow)/$($assignment.endpointId)/$($assignment.roleIndex)"
        if (-not $seen.Add($identity)) { throw "Duplicate priority assignment '$identity'." }
        $registryFlow = if ([string]$assignment.flow -eq 'render') { 'Render' } else { 'Capture' }
        $endpointPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$registryFlow\$($assignment.endpointId)"
        if (-not (Test-Path -LiteralPath $endpointPath -PathType Container)) { throw "Priority endpoint is not registered: $identity" }
    }
    [pscustomobject]@{ Path=$resolved; Plan=$plan; Count=@($plan.assignments).Count; Bytes=$bytes; Sha256=$actualSha256 }
}

function Get-PriorityBundleHash {
    param([Parameter(Mandatory)][string]$Directory)
    $entries = foreach ($name in @('Set-AudioPriority.ps1','WindowsAudioProfile.psm1','CoreAudio.cs')) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Priority bundle file is missing: $name" }
        "$name`:$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
        ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function New-ProtectedPriorityStagingDirectory {
    $path = Join-Path $env:ProgramData ('DSNTools-WindowsAudioProfile-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($administrators)
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
        Set-Acl -LiteralPath $path -AclObject $acl
        $verifiedAcl = Get-Acl -LiteralPath $path
        if (-not $verifiedAcl.AreAccessRulesProtected) { throw 'Priority staging directory still inherits access rules.' }
        $allowedSids = @($administrators.Value, $system.Value)
        foreach ($rule in $verifiedAcl.Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($rule.AccessControlType -eq $allow -and $allowedSids -notcontains $sid) { throw "Priority staging grants access to unexpected identity '$sid'." }
        }
        $path
    }
    catch {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

try {
    if ($Mode -in @('System','TrustedInstaller')) {
        if ([string]::IsNullOrWhiteSpace($PlanSha256) -or [string]::IsNullOrWhiteSpace($BundleSha256)) { throw "$Mode mode requires plan and bundle hashes." }
        $actualBundleHash = Get-PriorityBundleHash -Directory $PSScriptRoot
        if (-not [string]::Equals($actualBundleHash, $BundleSha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'Priority bundle hash verification failed.' }
    }
    $validated = Import-PriorityPlan -Path $PlanPath -ExpectedSha256 $PlanSha256
    $resultPath = "$($validated.Path).result.json"
    $errorPath = "$($validated.Path).error.json"
    if ($Mode -eq 'Validate') {
        $result = [pscustomobject]@{ valid=$true; plan=$validated.Path; assignments=$validated.Count }
        if ($Json) { $result | ConvertTo-Json -Depth 4 -Compress } else { Write-Output "Priority plan is valid: $($validated.Count) assignment(s)." }
        exit 0
    }

    if ($Mode -eq 'TrustedInstaller') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.User.Value -ne 'S-1-5-18') { throw 'TrustedInstaller mode requires the local SYSTEM identity.' }
        $trustedInstallerSid = ([Security.Principal.NTAccount]::new('NT SERVICE', 'TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($identity.Groups.Value -notcontains $trustedInstallerSid) { throw 'TrustedInstaller service SID is missing from the process token.' }
        $audioRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
        $operations = @(Set-AudioPriorityRegistryValues -AudioRoot $audioRoot -Assignments @($validated.Plan.assignments))
        $result = [pscustomobject]@{ completed=$true; mode=$Mode; assignments=$validated.Count; operations=$operations.Count; planHashVerified=$true; bundleHashVerified=$true }
        [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        exit 0
    }

    if ($Mode -eq 'System') {
        if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { throw 'System mode requires the local SYSTEM identity.' }
        Initialize-AudioInterop
        $service = Get-Service -Name 'TrustedInstaller'
        $startedService = $service.Status -ne 'Running'
        try {
            if ($startedService) { Start-Service -Name 'TrustedInstaller' }
            $deadline = (Get-Date).AddSeconds(15)
            do {
                $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='TrustedInstaller'"
                if ($serviceInfo.State -eq 'Running' -and [uint32]$serviceInfo.ProcessId -gt 0) { break }
                Start-Sleep -Milliseconds 200
            } while ((Get-Date) -lt $deadline)
            if ($serviceInfo.State -ne 'Running' -or [uint32]$serviceInfo.ProcessId -eq 0) { throw 'TrustedInstaller did not expose a running process.' }
            $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -Mode TrustedInstaller -PlanPath "{2}" -PlanSha256 "{3}" -BundleSha256 "{4}"' -f $powerShell, $PSCommandPath, $validated.Path, $PlanSha256, $BundleSha256
            $exitCode = [DSNTools.WindowsAudioProfile.TokenRunner]::RunFromProcessToken([uint32]$serviceInfo.ProcessId, $powerShell, $arguments, $PSScriptRoot, 60000)
            if ($exitCode -ne 0) { throw "TrustedInstaller worker exited with code $exitCode." }
            if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'TrustedInstaller worker did not create its result file.' }
        }
        finally {
            if ($startedService) {
                $service = Get-Service -Name 'TrustedInstaller'
                if ($service.Status -ne 'Stopped') { Stop-Service -Name 'TrustedInstaller' -Force -ErrorAction Stop }
                $service = Get-Service -Name 'TrustedInstaller'
                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
                if ($service.Status -ne 'Stopped') { throw 'TrustedInstaller did not return to its previous stopped state.' }
            }
        }
        exit 0
    }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Controller mode requires an elevated administrator token.' }
    $stagingPath = $null
    $taskName = $null
    try {
        $stagingPath = New-ProtectedPriorityStagingDirectory
        foreach ($name in @('Set-AudioPriority.ps1','WindowsAudioProfile.psm1','CoreAudio.cs')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stagingPath $name)
        }
        $stagedPlan = Join-Path $stagingPath 'plan.json'
        [IO.File]::WriteAllBytes($stagedPlan, $validated.Bytes)
        $stagedPlanHash = $validated.Sha256
        $stagedBundleHash = Get-PriorityBundleHash -Directory $stagingPath
        $stagedScript = Join-Path $stagingPath 'Set-AudioPriority.ps1'
        $resultPath = "$stagedPlan.result.json"
        $errorPath = "$stagedPlan.error.json"
        $taskName = 'DSN-WindowsAudioProfile-' + [guid]::NewGuid().ToString('N')
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode System -PlanPath "{1}" -PlanSha256 "{2}" -BundleSha256 "{3}"' -f $stagedScript, $stagedPlan, $stagedPlanHash, $stagedBundleHash
        $action = New-ScheduledTaskAction -Execute $powerShell -Argument $taskArguments
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $settings | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 300
            $task = Get-ScheduledTask -TaskName $taskName
            if ((Test-Path -LiteralPath $resultPath -PathType Leaf) -and $task.State -ne 'Running') { break }
        } while ((Get-Date) -lt $deadline)
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($task.State -eq 'Running') { throw 'Priority task exceeded its controller timeout.' }
        if ($info.LastTaskResult -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Priority task failed with result $($info.LastTaskResult)."
        }
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        $result | Add-Member -NotePropertyName 'stagingProtected' -NotePropertyValue $true -Force
        $result | Add-Member -NotePropertyName 'planHashVerified' -NotePropertyValue $true -Force
        $result | Add-Member -NotePropertyName 'bundleHashVerified' -NotePropertyValue $true -Force
        if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress } else { Write-Output "Applied $($result.assignments) priority assignment(s)." }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($taskName)) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                if ($task.State -eq 'Running') {
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    $stopDeadline = (Get-Date).AddSeconds(10)
                    do {
                        Start-Sleep -Milliseconds 200
                        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    } while ($null -ne $task -and $task.State -eq 'Running' -and (Get-Date) -lt $stopDeadline)
                }
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($stagingPath) -and (Test-Path -LiteralPath $stagingPath)) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
    }
    exit 0
}
catch {
    if ($null -ne $errorPath) {
        try { [IO.File]::WriteAllText($errorPath, ([pscustomobject]@{ mode=$Mode; error=$_.Exception.Message } | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false)) } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
