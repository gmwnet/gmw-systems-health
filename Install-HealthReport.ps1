#Requires -Version 5.1
<#
.SYNOPSIS
    Provisions the GMW health reporter on a workstation.

.DESCRIPTION
    Consumes provision.json, which is minted server-side at registration. Installs the
    collector and a DPAPI-protected client key into a SYSTEM/Administrators-only folder,
    runs the collector once to prove it works, then deletes provision.json.

    The agent is registered as a scheduled task, never as a Windows service. That is a
    deliberate standing choice: nothing of ours stays resident between runs. See DESIGN
    RULE 4 in HealthReport.ps1 for the reasoning.

    The key never appears on the console, and it never touches disk unencrypted.

.PARAMETER RootDir
    Install root. Default: C:\ProgramData\GMWSystemsHealth
    Tests may point this at a scratch directory; nothing outside it is touched.

.PARAMETER Task
    Accepted for compatibility and passed by Install.cmd. The SYSTEM scheduled task is
    registered by default; use -NoTask to provision without it.

.PARAMETER NoTask
    Provision only, without registering the scheduled task. The collector then runs only
    when someone starts it by hand, so no reports ever arrive on their own. Intended for
    inspecting an install, not for deploying an agent.

.PARAMETER Uninstall
    Remove the scheduled task and the install root.

.PARAMETER TestMode
    Skip elevation and ACL hardening, for local testing only. Refused unless -RootDir is
    given explicitly and points outside ProgramData and Program Files, so it cannot be used
    to produce an unhardened install in the real location.

.EXAMPLE
    .\Install-HealthReport.ps1 -RootDir .\..\_dev\testroot

.EXAMPLE
    .\Install-HealthReport.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $RootDir,
    [string] $ProvisionFile,
    [string] $TaskName = 'GMW Systems Health Report',

    # First run of the day, LOCAL time. 05:00 so a fresh report is waiting when the
    # office opens. Local time means it follows daylight saving with no extra work.
    [string] $At = '05:00',

    # Must divide 24 evenly, or the runs are unevenly spaced. 6 = four runs a day
    # (05:00, 11:00, 17:00, 23:00). Change this and the whole schedule follows.
    [ValidateSet(1, 2, 3, 4, 6, 8, 12)]
    [int] $EveryHours = 6,

    [switch] $Task,
    [switch] $NoTask,
    [switch] $Uninstall,
    [switch] $TestMode
)

$ErrorActionPreference = 'Stop'

# Scheduling is the normal operating mode, so the task is registered unless someone opts
# out. It used to be opt-in (-Task) while the upload path was being built; that default
# outlived its reason, and a bundle installed without it reports once and then goes quiet,
# which on the server looks exactly like a healthy machine. -Task is still accepted so an
# existing command line keeps working; -NoTask is the documented opt-out.
$registerTask = -not $NoTask

# PowerShell 5.1: $PSScriptRoot is not reliable in param defaults. Resolve it here.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $RootDir)       { $RootDir = Join-Path $env:ProgramData 'GMWSystemsHealth' }
if (-not $ProvisionFile) { $ProvisionFile = Join-Path $scriptDir 'provision.json' }
$RootDir       = [IO.Path]::GetFullPath($RootDir)
$ProvisionFile = [IO.Path]::GetFullPath($ProvisionFile)

# The install folder was renamed from WindowsHealthReport after 0.1.3, because that name
# reads like a Microsoft component while sitting in a directory full of vendor folders. A
# machine still carrying the old root has its OWN sealed key and scheduled task, so
# installing under the new name would leave two agents reporting under one agent ID. Refuse
# and point at the old uninstaller rather than quietly creating that mess.
$legacyRoot = Join-Path $env:ProgramData 'WindowsHealthReport'
if (-not $TestMode -and -not $Uninstall -and (Test-Path -LiteralPath $legacyRoot) -and
    $RootDir -ne [IO.Path]::GetFullPath($legacyRoot)) {
    Write-Host "An older install is present at $legacyRoot" -ForegroundColor Red
    Write-Host 'Remove it first, then run this installer again:' -ForegroundColor Red
    Write-Host ("  powershell -ExecutionPolicy Bypass -File `"{0}\Install-HealthReport.ps1`" -Uninstall" -f $legacyRoot) -ForegroundColor Red
    exit 1
}

# TestMode skips ACL hardening. That is fine in a scratch directory and unacceptable in the
# real one, so require an explicit root and refuse anything that looks like a system install
# location - this switch must not be able to produce an unhardened production agent.
if ($TestMode) {
    if (-not $PSBoundParameters.ContainsKey('RootDir')) {
        Write-Host '-TestMode requires an explicit -RootDir outside ProgramData/Program Files.' -ForegroundColor Red
        exit 1
    }
    foreach ($forbidden in @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($forbidden -and $RootDir.StartsWith($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "-TestMode will not run against $forbidden" -ForegroundColor Red
            exit 1
        }
    }
}

$LogFile = Join-Path $RootDir 'install.log'

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} {1,-5} {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if (Test-Path $RootDir) { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 }
    } catch { }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal -ArgumentList $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RootAcl {
    param([string] $Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
               [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagate = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($who in @('SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $who, 'FullControl', $inherit, $propagate, 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Path -AclObject $acl
}

# ------------------------------------------------------------------ uninstall --
#
# Removal is the whole footprint and nothing else: stop the task, unregister it,
# delete the folder. No registry key to hunt for, no service to deregister, no
# entry in Add/Remove Programs (DESIGN RULE 5 in HealthReport.ps1).

if ($Uninstall) {
    if (-not $TestMode -and -not (Test-Elevated)) { Write-Host 'Elevation required.' -ForegroundColor Red; exit 1 }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {

        # Stop a run that is in progress before removing its files. Deleting the
        # script out from under a running copy fails halfway and leaves a
        # half-removed install, which is exactly the mess we are avoiding.
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'"
    } else {
        Write-Host "No scheduled task '$TaskName'"
    }

    if (Test-Path -LiteralPath $RootDir) {
        Write-Host "Removing $RootDir"
        Remove-Item -LiteralPath $RootDir -Recurse -Force
    }

    Write-Host 'Done. Nothing else was registered, so nothing else needs removing.'
    exit 0
}

# ---------------------------------------------------------------------- preflight --

if (-not $TestMode -and -not (Test-Elevated)) {
    Write-Host 'Elevation required. Right-click Install.cmd and choose Run as administrator.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $ProvisionFile)) {
    Write-Host "Missing $ProvisionFile" -ForegroundColor Red
    Write-Host 'The bundle is generated at registration; do not hand-craft it.' -ForegroundColor Red
    exit 1
}

$prov = Get-Content -LiteralPath $ProvisionFile -Raw | ConvertFrom-Json
$agentId    = [string]$prov.agentId
$keyHex     = [string]$prov.key
$reportUrl  = [string]$prov.reportUrl

$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
if ($agentId -notmatch $guidPattern) {
    Write-Host 'provision.json: agentId is not a GUID' -ForegroundColor Red; exit 1
}
if ($keyHex -notmatch '^[0-9a-fA-F]{64}$') {
    Write-Host 'provision.json: key must be 64 hex characters' -ForegroundColor Red; exit 1
}
if ($reportUrl -notmatch '^https://') {
    Write-Host 'provision.json: reportUrl must be https' -ForegroundColor Red; exit 1
}

$collectorSrc = Join-Path $scriptDir 'HealthReport.ps1'
if (-not (Test-Path -LiteralPath $collectorSrc)) {
    Write-Host "Missing $collectorSrc (must sit beside this installer)" -ForegroundColor Red; exit 1
}
if ($registerTask -and -not (Select-String -LiteralPath $collectorSrc -Pattern '\[switch\]\s*\$Send' -Quiet)) {
    Write-Host 'Collector has no -Send switch; refusing to register a task that discards its report' -ForegroundColor Red
    Write-Host 'This bundle is incomplete - download it again rather than installing this copy.' -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------- install --

# Nothing in this installer touches the registry. The footprint is this folder plus
# one scheduled task; nothing else on the machine changes (DESIGN RULE 5). Every
# artefact below lives under $RootDir, which is why removal is delete-the-folder.

New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
if ($TestMode) {
    Write-Log 'TestMode: ACL hardening skipped' 'WARN'
} else {
    Set-RootAcl -Path $RootDir
    Write-Log "Install root $RootDir (SYSTEM + Administrators only)"
}

# Key: DPAPI LocalMachine by default. ProtectedData lives in System.Security.dll,
# which PowerShell 5.1 does not have loaded by default.
Add-Type -AssemblyName System.Security -ErrorAction Stop
$keyBytes = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $keyBytes[$i] = [Convert]::ToByte($keyHex.Substring($i * 2, 2), 16) }

$keyPath = Join-Path $RootDir 'client.key'

# Always DPAPI-sealed, always LocalMachine scope. There is no plaintext path: a switch to
# write the key unencrypted is exactly the kind of convenience that ends up in a client
# bundle because someone was debugging.
$sealed = [System.Security.Cryptography.ProtectedData]::Protect(
    $keyBytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes($keyPath, $sealed)
Write-Log 'Key sealed with DPAPI (LocalMachine)'

# Agent config: not secret.
$agentCfg = [ordered]@{ agentId = $agentId; reportUrl = $reportUrl } | ConvertTo-Json
[IO.File]::WriteAllText(
    (Join-Path $RootDir 'agent.json'), $agentCfg, (New-Object System.Text.UTF8Encoding $false))

$collectorDst = Join-Path $RootDir 'HealthReport.ps1'
Copy-Item -LiteralPath $collectorSrc -Destination $collectorDst -Force
Write-Log "Collector installed to $collectorDst"

# Prove it runs before deleting the only copy of the key.
$probe = Join-Path $RootDir 'report.selfcheck.json'
& $collectorDst -AgentConfig (Join-Path $RootDir 'agent.json') -Fast -OutFile $probe
if (-not (Test-Path $probe)) { Write-Log 'Self-check produced no report' 'ERROR'; exit 1 }
$probeJson = Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
$sectionCount = @($probeJson.PSObject.Properties).Count
$errorCount = @($probeJson.collectionErrors).Count
Write-Log "Self-check OK: $sectionCount sections, $errorCount collection error(s)"
Remove-Item -LiteralPath $probe -Force

# The key is now in the protected config. Overwrite the provisioning copies before
# unlinking them: a plain delete leaves the plaintext key readable in free space for
# anyone with raw disk access, which defeats the point of sealing it at all.
function Remove-Secret {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        $noise = New-Object byte[] ([Math]::Max(1, $len))
        (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($noise)
        [IO.File]::WriteAllBytes($Path, $noise)
    }
    catch { }
    Remove-Item -LiteralPath $Path -Force
}

Remove-Secret -Path $ProvisionFile
Write-Log "Wiped then deleted $ProvisionFile (it contained the key)"

$bundleCopy = Join-Path $scriptDir 'provision.json'
if (Test-Path -LiteralPath $bundleCopy) {
    Remove-Secret -Path $bundleCopy
    Write-Log 'Wiped then deleted the bundle copy of provision.json'
}

# ---------------------------------------------------------------------- task --

# Scheduled task, not a service. The task exists for a few seconds twice a day and
# then vanishes; a service would sit in memory doing nothing for the other 23h59m.
# Consequences that are intentional, not incidental:
#   - "StartWhenAvailable" makes a missed run (machine asleep) catch up on wake,
#     which is the only scheduling behaviour we actually need from a service.
#   - "MultipleInstances IgnoreNew" prevents two copies fighting over the spool.
#   - The 30 minute random delay stops an entire fleet waking up and posting in the
#     same minute, which would look like an incident on the collector.
#   - Everything here runs as SYSTEM, so no stored password and no user session.

if ($registerTask) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Send' -f $collectorDst
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine

    $first = [datetime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $perDay = [int](24 / $EveryHours)

    # One daily trigger per run, spaced $EveryHours apart. Every trigger gets the
    # same random delay so a fleet never posts in lockstep, and the delay stays
    # well inside the interval (30 min against 8 h), so runs cannot reorder.
    $daily = @()
    for ($i = 0; $i -lt $perDay; $i++) {
        $daily += New-ScheduledTaskTrigger -Daily -At $first.AddHours($i * $EveryHours) `
                        -RandomDelay (New-TimeSpan -Minutes 30)
    }

    # Two catch-up triggers, because they cover different failures.
    #
    # At-startup: the machine was off all day, so it reports on the next boot
    # rather than waiting for the next scheduled slot.
    #
    # At-logon: startup does not always happen the way people assume. A machine
    # that hibernates, or uses Fast Startup, resumes without running any boot
    # trigger; a workstation that boots to a lock screen and sits there for hours
    # has technically started but is doing nothing useful. A logon always happens,
    # which makes this the reliable "a human is here now" signal.
    #
    # The 2 minute delay keeps a WMI sweep and an update search out of the logon
    # storm, which is the worst possible moment to start them, and gives the
    # desktop time to finish loading. PowerShell 5.1 has no -Delay parameter on
    # -AtLogOn (it is on -Daily), so the property is set afterwards.
    $atLogon = New-ScheduledTaskTrigger -AtLogOn
    $atLogon.Delay = 'PT2M'

    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        $atLogon
    ) + $daily

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force `
        -Description 'GMW health and Windows Update reporter' | Out-Null
    Write-Log "Scheduled task '$TaskName' registered (startup + logon + $perDay runs/day from $At, every ${EveryHours}h, SYSTEM)"
} else {
    Write-Log 'Task not registered (-NoTask). Provisioning only.'
}

Write-Log "Done. Agent $agentId"
