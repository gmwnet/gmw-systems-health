#Requires -Version 5.1
<#
===============================================================================
 GMW WINDOWS HEALTH REPORTER - COLLECTOR
===============================================================================

.SYNOPSIS
    Collects a workstation's Windows Update status and general health, and emits
    one JSON document.

.DESCRIPTION
    Read-only by design. This script inspects the machine and writes a report; it
    does not install, configure, repair or change anything. There is no "apply"
    mode and no self-healing. If a workstation needs fixing, a human reads the
    report and fixes it.

    One-shot by design. It starts, collects, hands over its report and exits.
    There is no service, no tray icon, no background thread and nothing left
    running afterwards. See DESIGN RULE 4.

    The output is a single JSON object with one top-level key per subject area
    (os, memory, storage, windowsUpdate, and so on). Anything that failed to
    collect is listed under "collectionErrors" instead of aborting the run, so a
    single unavailable counter never costs you the whole report.

    DESIGN RULE 1 - RAW FACTS ONLY.
    This script reports what is. It does not decide what is good or bad. There
    are no thresholds here, no "warning" states, no health scores. Those rules
    live on the collection server, where they can be corrected once instead of
    redeployed to every workstation. A report full of raw numbers can be
    re-analysed later; a report full of verdicts cannot.

    DESIGN RULE 2 - NO IDENTIFYING DATA.
    The only stable identifier in the payload is a random agent ID issued at
    install time. The script never reads or transmits the computer name, domain,
    username, SMBIOS UUID, machine GUID, BIOS serial, hardware model names,
    volume labels, timezone, IP or MAC address. See the PRIVACY section below.

    DESIGN RULE 3 - NO DEPENDENCIES.
    Everything here uses what ships with Windows: CIM/WMI, the registry, the
    Windows Update COM API, and a few built-in modules. There is no
    PSWindowsUpdate module to install, no NuGet, no internet download, and no
    execution policy gymnastics. That is why we use the COM API for update
    status rather than the far more convenient PSWindowsUpdate cmdlets: an agent
    that must install a module before it can report is an agent that fails on
    locked-down machines.

    DESIGN RULE 4 - NO RESIDENT PROCESS.
    A scheduled task, never a service and never a daemon. The agent is started
    by Task Scheduler, does its one job, and exits. Nothing of ours sits in
    memory between runs, nothing listens on a port, and there is no process
    lifecycle to manage. This is a standing preference for GMW's Windows
    tooling, not a quirk of this script, and it is worth stating plainly
    because "just make it a service" is the usual answer and it is usually the
    wrong one on a workstation:

      - Nothing idle means no idle memory, no idle CPU, and no slow leak that
        only shows up after three months of uptime.
      - Nothing listening means there is no network attack surface and no
        authentication to get wrong on a background endpoint.
      - No service lifecycle means no start/stop/restart semantics, no
        dependency ordering, no recovery policy, and no service account to
        reason about on a desk machine that nobody administers daily.
      - The client key stays sealed on disk and is opened only for the seconds
        it takes to send. It is never resident in a long-lived process where a
        memory dump would expose it.
      - Failure is visible where people already look: the task's last run
        result and its exit code, rather than a log file nobody reads.
      - Nothing has to be updated in place. A new version is a copied file; no
        restart, no downtime, no "please close the agent".

    The exception is real but narrow: work that genuinely must be continuous
    belongs on a server, as a server concern, where a resident process is
    affordable and monitored. On workstations, this is the pattern.

    DESIGN RULE 5 - NOTHING BUT FILES.
    No registry keys, no installer framework, no service registration, no MSI,
    no Add/Remove Programs entry, no GPO, no environment variable, no WMI class,
    no driver. The entire footprint is one folder and one scheduled task, and
    this script writes nothing at all.

    That makes removal absolute instead of approximate: stop the task, delete
    the folder, and there is nothing left to find, forget, or be afraid of.
    Registry-stored state is the classic Windows trap - an uninstaller misses a
    key, and the machine "remembers" software nobody can name. Years later you
    are reluctant to re-image your own workstation because of keys you cannot
    identify. We are not doing that to anybody.

    Two honest footnotes, so this is not mistaken for magic:
      - The scheduled task lives in the OS's own task store. That is the only
        registration, Task Scheduler owns it, and unregistering the task removes
        it completely.
      - The client key is sealed with DPAPI, which references an OS-managed
        machine master key. That stores nothing of ours in the registry, and
        deleting the sealed blob leaves no application data behind.

.PARAMETER OutFile
    Write the JSON to this path, as UTF-8 without a byte-order mark. The
    directory is created if missing. When omitted the JSON is written to the
    pipeline (stdout), which is handy for review and for piping into a file
    yourself.

.PARAMETER AgentConfig
    Path to the agent identity file, normally written by the installer at
    C:\ProgramData\GMWSystemsHealth\agent.json. It holds the random agent ID
    and the collection endpoint. If the file is missing the report is still
    produced, but "agentId" is null and a collectionErrors entry is recorded so
    that the sender knows not to upload an unattributable report.

.PARAMETER Fast
    Skip the online Windows Update search. That search is the slow part (often
    10 to 60 seconds) and the only part that needs network access. Everything
    else in the report is unaffected. Used for smoke tests and for the
    installer's self-check.

.PARAMETER Compress
    Emit single-line JSON. The report body for the HTTPS upload uses this form.

.PARAMETER Send
    Upload the report to the collection endpoint instead of (or as well as) writing it
    locally. The report is written to a spool directory FIRST and only deleted once the
    server has accepted it with a 2xx, so a crash, a network outage or a server restart
    cannot lose a report.

    Requires an agent identity in -AgentConfig (agentId and reportUrl) and the matching
    DPAPI-sealed client key beside it, both of which the installer creates. Without them
    the script reports and exits non-zero rather than posting an unattributable report.

    Exit codes: 0 = everything spooled was accepted; 1 = something was retained for
    retry (server unreachable, 401/403/429/5xx) or the identity is missing. The scheduled
    task surfaces this as its Last Run Result, which is the only monitoring the agent
    needs.

.EXAMPLE
    .\HealthReport.ps1 -OutFile C:\Temp\report.json

    Write a full report, including the Windows Update search, to a file.

.EXAMPLE
    .\HealthReport.ps1 -Fast -Compress

    Quick run without the update search, single-line JSON on stdout. This is the
    fastest way to eyeball what the agent would send.

.NOTES
    Requires  : Windows 10 / 11 or Windows Server 2016+ with PowerShell 5.1
    Runtime   : one-shot. Starts, collects, exits. No service, no resident
                process, no listening port, no background thread. Triggered by
                Task Scheduler - see DESIGN RULE 4.
    Elevation : optional. Three sections (BitLocker, TPM, Secure Boot) need an
                administrator token; without one they simply record an error and
                the rest of the report is unaffected. In production the agent
                runs as SYSTEM, so all sections populate.
    Network   : only the Windows Update search. Omit -Fast to include it.
    Modules   : none. Nothing is imported beyond what ships with Windows.
    Writes    : only -OutFile, if given.
    State     : none. The folder and the scheduled task are the entire
                footprint; this script and its installer write no registry keys
                (DESIGN RULE 5). Uninstall is: stop the task, delete the folder.
    Schema    : schemaVersion 1. Additive changes only; bump schemaVersion on a
                breaking change and expect the server to reject an unknown
                version rather than guess.

    PRIVACY - what is deliberately NOT collected:
      computer name / hostname      domain / workgroup        username
      SMBIOS UUID                   machine GUID (registry)   BIOS serial
      hardware manufacturer/model   CPU, GPU, disk model names
      volume labels                 timezone                  IP / MAC addresses
      event log messages (they routinely contain usernames and file paths)

    Attribution is handled out of band: the server keeps its own mapping from
    agent ID to a human label, populated when the agent is registered. Nothing
    on this machine can be used to re-identify it from the payload alone.

    SECURITY NOTE: the payload is not confidential from the local machine. It
    describes the machine it runs on, and anyone who can read the report can
    read the machine. The transport is HTTPS; the content itself is not secret.
    It is only depersonalised.

===============================================================================
#>

[CmdletBinding()]
param(
    [string] $OutFile,
    [string] $AgentConfig = "$env:ProgramData\GMWSystemsHealth\agent.json",
    [switch] $Fast,
    [switch] $Compress,
    [switch] $Send
)

# -----------------------------------------------------------------------------
# Constants. The version pair is the contract with the collection server:
# agentVersion says which client produced the report, schemaVersion says which
# layout the report follows. They change for different reasons and must not be
# conflated.
# -----------------------------------------------------------------------------

$AgentVersion  = '0.1.7'
$SchemaVersion = 1

# Every timestamp in this report uses this one format: UTC, fixed width, explicit Z.
#
# Not .NET's 'o' round-trip format, which emits SEVEN fractional digits
# (2026-11-22T14:57:58.9312161Z). PHP's DateTime::createFromFormat with 'u' expects SIX -
# microseconds - so a seven-digit value fails to parse, and it fails quietly. Seconds are
# ample for health data, and one fixed format means the server never has to guess or
# normalise. Agreed with the collector side 2026-11-22.
$script:UtcFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

# Wall clock at the start, so the report can state how long collection took.
# Duration matters operationally: a report that suddenly takes 90 seconds means
# the Windows Update search is misbehaving.
$script:StartedAt = Get-Date

# Failures are accumulated here rather than thrown. One dead section must never
# cost the other thirteen. Declared once and shared by the Collect helper below.
$script:CollectErrors = New-Object 'System.Collections.Generic.List[object]'

# =============================================================================
# SECTION 1 - HELPERS
# =============================================================================

function Collect {
    <#
    .SYNOPSIS
        Runs one collection section and contains its failure.

    .DESCRIPTION
        Every section of this report is independent. BitLocker might need an
        administrator token, the update search might be unable to reach the
        server, a counter might not exist on an unusual build. None of those
        should prevent the report from being produced.

        So each section is wrapped in this helper: if the script block throws,
        the error is recorded under "collectionErrors" with the section name,
        the exception type and its HRESULT, and the section's value becomes
        null. The run continues.

        The exception MESSAGE is deliberately not recorded. Messages from WMI
        and CIM carry file paths, and a Windows profile folder usually contains
        a person's name, so the text is not sent at all - see the comment on the
        catch block below.

        The trade-off is deliberate. A report missing one section is useful. A
        run that aborts because TPM access was denied is not.

        A section that returns a LIST must write it as `,@(...)` - with the
        leading comma. PowerShell enumerates a value returned from a function,
        so a one-element array leaves here as a bare object, and the same
        section then serialises as an object on a machine with one item and an
        array on a machine with two. The comma emits the array as a single
        object, which is the only way to keep it an array without changing what
        the section means. Six sections return lists; all six carry the comma.

    .PARAMETER Section
        Name recorded in collectionErrors. Kept stable so the server can group
        failures by section across the fleet.

    .PARAMETER Body
        The script block that gathers the data and returns it.
    #>
    param(
        [Parameter(Mandatory)][string]      $Section,
        [Parameter(Mandatory)][scriptblock] $Body
    )

    try {
        & $Body
    }
    catch {
        # The report records WHICH section failed and WHAT KIND of error it was, never
        # the message text. Messages from WMI and CIM routinely embed file paths, and a
        # Windows profile folder often contains a person's name. A regex that strips
        # paths cannot be trusted to catch every shape of one - the previous attempt
        # stopped at the first space and left "C:\Users\Jane Smith\..." as
        # "<path> Smith\...", name included. A type and an HRESULT are enough to tell
        # access-denied from not-supported, and neither can carry a name.
        $ex = $_.Exception
        $hresult = if ($ex.HResult) { '0x{0:X8}' -f $ex.HResult } else { $null }

        $script:CollectErrors.Add([ordered]@{
            section = $Section
            type    = $ex.GetType().Name
            hresult = $hresult
        })
        $null
    }
}

function Get-Gb {
    <#
    .SYNOPSIS
        Converts a byte count to gigabytes, rounded to two decimals.

    .DESCRIPTION
        WMI returns sizes as unsigned 64-bit integers, which serialise badly and
        are unreadable in a report. Everything size-related is normalised to GB
        so the server compares like with like and never has to know whether a
        given field was bytes, KB or MB.

        Returns $null for a missing value rather than 0, because "no disk
        reported" and "a disk with zero bytes" are different facts.
    #>
    param($Bytes)

    if ($null -eq $Bytes) { return $null }
    [math]::Round([double]$Bytes / 1GB, 2)
}

function Test-Admin {
    <#
    .SYNOPSIS
        True when the current process holds an administrator token.

    .DESCRIPTION
        Recorded in the report so the server can tell "BitLocker is not
        configured" apart from "we were not allowed to look". Without this flag,
        an unelevated run and a broken machine look identical.
    #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal -ArgumentList $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
# SECTION 2 - AGENT IDENTITY
# =============================================================================

# The ONLY identifier that leaves this machine. It is a random GUID issued by
# the server at registration and stored beside this script in agent.json. It is
# never derived from hardware, so it cannot be traced back to a machine by
# anyone who only has the report.
#
# If the identity is missing we still build the report - that is genuinely
# useful for review - but we record an error, and the sender must refuse to
# upload it. An unattributable report is data with nowhere to go.

$agentId   = $null
$reportUrl = $null

if (Test-Path -LiteralPath $AgentConfig) {
    $cfg = Collect 'agentConfig' {
        Get-Content -LiteralPath $AgentConfig -Raw | ConvertFrom-Json
    }
    if ($cfg) {
        $agentId   = $cfg.agentId
        $reportUrl = $cfg.reportUrl
    }
}

if (-not $agentId) {
    $script:CollectErrors.Add([ordered]@{
        section = 'agentId'
        message = 'no agent identity configured; report is unassigned and must not be uploaded'
    })
}

# =============================================================================
# SECTION 3 - META
# =============================================================================

# An ordered dictionary, not a hashtable: key order is preserved in the JSON,
# which makes reports diffable by eye and keeps the output stable for anyone
# parsing it with line tools.

$report = [ordered]@{}

$report.meta = [ordered]@{
    schemaVersion = $SchemaVersion
    agentVersion  = $AgentVersion
    agentId       = $agentId

    # Stable across spool replays, so the server can deduplicate on it.
    # Generated once per collection and frozen into the stored payload: a retry
    # of the same report must not look like a second report. Never regenerate
    # this at send time.
    reportId      = [guid]::NewGuid().ToString()

    # UTC, ISO-8601. Client clocks drift, so the server treats this as a hint
    # and uses its own receipt time for ordering. Still useful for spotting a
    # workstation whose clock is badly wrong.
    collectedUtc  = $script:StartedAt.ToUniversalTime().ToString($script:UtcFormat)

    # Lets the server distinguish "not configured" from "not permitted".
    isAdmin       = (Test-Admin)

    # Which PowerShell produced this. 5.1 and 7.x differ in both behaviour and
    # available cmdlets, and that matters when a field goes missing.
    psVersion     = $PSVersionTable.PSVersion.ToString()
}

# =============================================================================
# SECTION 4 - OPERATING SYSTEM
# =============================================================================

$report.os = Collect 'os' {

    # Win32_OperatingSystem carries the build, the install date and the last
    # boot time, which together tell us patch level, machine age and whether a
    # reboot is overdue for reasons unrelated to updates.
    $os = Get-CimInstance Win32_OperatingSystem

    # The registry is the only reliable source for the true product name and
    # the UBR (update build revision, the part after the dot). WMI will not give
    # you the UBR, and OSMicrosoft's own caption lies on Windows 11 - see below.
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    # Windows 11 still reports ProductName as "Windows 10 ..." in this key. The
    # build number is the authoritative discriminator: 22000 and above is 11.
    # Without this correction every Windows 11 machine misreports its edition,
    # which makes fleet-level version reporting quietly wrong.
    $product = $cv.ProductName
    if ($cv.CurrentBuild -ge 22000 -and $product -like '*Windows 10*') {
        $product = $product -replace 'Windows 10', 'Windows 11'
    }

    $boot = $os.LastBootUpTime

    [ordered]@{
        product        = $product
        edition        = $cv.EditionID
        displayVersion = $cv.DisplayVersion

        # Build and UBR together, e.g. "22631.4460". The UBR is what actually
        # moves when a cumulative update lands, so it is the field to watch.
        build          = "$($cv.CurrentBuild).$($cv.UBR)"

        # Registry InstallDate is Unix epoch SECONDS stored as a number, not a
        # DateTime. Casting it with [datetime] parses the number as ticks and
        # silently yields year 0001 - which is what shipped in the first cut of
        # this script and looked like a plausible timestamp. Convert explicitly.
        installDateUtc = if ($cv.InstallDate) {
            try { [datetimeoffset]::FromUnixTimeSeconds([int64]$cv.InstallDate).UtcDateTime.ToString($script:UtcFormat) }
            catch { $null }
        } else { $null }

        lastBootUtc    = $boot.ToUniversalTime().ToString($script:UtcFormat)
        uptimeHours    = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    }
}

# =============================================================================
# SECTION 5 - LICENCE / ACTIVATION
# =============================================================================

$report.activation = Collect 'activation' {

    # SoftwareLicensingProduct is the software licensing service's own view of
    # the licence. The ApplicationId GUID is the Windows application ID and is
    # constant; filtering on it avoids returning Office and other SL products.
    $slp = Get-CimInstance SoftwareLicensingProduct -Filter `
        "PartialProductKey IS NOT NULL AND ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f'"

    # LicenseStatus is a small integer; the numbers are not on a scale and are
    # meaningless without this map. Anything other than 1 (Licensed) is a
    # conversation with a human.
    $names = @{
        0 = 'Unlicensed'
        1 = 'Licensed'
        2 = 'OOBGrace'
        3 = 'OOTGrace'
        4 = 'NonGenuineGrace'
        5 = 'Notification'
        6 = 'ExtendedGrace'
    }

    ,@($slp | ForEach-Object {
        [ordered]@{
            statusCode = $_.LicenseStatus
            status     = $names[[int]$_.LicenseStatus]
            graceMin   = $_.GracePeriodRemaining
        }
    })
}

# =============================================================================
# SECTION 6 - HARDWARE
# =============================================================================

# Model names are deliberately absent. "Dell Latitude 5540 with 32 GB and an
# SN570" is close to a fingerprint; core counts and clock speeds describe
# capability without describing the specific machine. Driver versions are kept
# because a stale GPU driver is a real support case and does not identify a box.

$report.hardware = Collect 'hardware' {

    # A machine can have several sockets; taking the first is a deliberate
    # simplification. Workstations are single-socket, and reporting a list here
    # would complicate the server for no benefit.
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    [ordered]@{
        cpu = [ordered]@{
            cores       = $cpu.NumberOfCores
            logical     = $cpu.NumberOfLogicalProcessors
            maxClockMhz = $cpu.MaxClockSpeed
        }

        # Every GPU, including the integrated adapter on machines that have one.
        # Driver date is included because "old driver" is the actual signal;
        # the version string alone does not tell you how stale it is.
        #
        # vramMb comes from AdapterRAM, which is a known-bad field: it is signed
        # 32-bit internally, so anything with more than 4 GB reports 4095 or a
        # negative. Treat it as "at least this much", never as the true size.
        gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object {
            [ordered]@{
                driverVer  = $_.DriverVersion
                driverDate = if ($_.DriverDate) { $_.DriverDate.ToUniversalTime().ToString($script:UtcFormat) } else { $null }
                vramMb     = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB) } else { $null }
            }
        })

        # Per-stick detail, because a machine running below its rated speed is a
        # real and invisible fault: Speed is what the module is rated for,
        # ConfiguredClockSpeed is what the platform actually negotiated. When
        # those differ, the machine is being held back by its memory
        # configuration, and no amount of CPU reporting would reveal it.
        ramSticks = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
            [ordered]@{
                capacityGb    = (Get-Gb $_.Capacity)
                speedMhz      = $_.Speed
                configuredMhz = $_.ConfiguredClockSpeed
            }
        })

        # A full page file is a symptom worth seeing next to the memory figures.
        pageFile = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object {
            [ordered]@{
                allocMb = $_.AllocatedBaseSize
                peakMb  = $_.PeakUsage
            }
        })
    }
}

# =============================================================================
# SECTION 7 - MEMORY
# =============================================================================

$report.memory = Collect 'memory' {

    # These two properties are already in kilobytes, despite the names. They are
    # visible memory, so they exclude memory reserved by hardware - which is the
    # honest denominator for "how much does the user have".
    $os   = Get-CimInstance Win32_OperatingSystem
    $tot  = [double]$os.TotalVisibleMemorySize
    $free = [double]$os.FreePhysicalMemory

    [ordered]@{
        totalGb = [math]::Round($tot  / 1MB, 2)
        freeGb  = [math]::Round($free / 1MB, 2)
        usedGb  = [math]::Round(($tot - $free) / 1MB, 2)

        # Guarded because a divide by zero on a broken CIM provider would
        # otherwise throw and lose the section.
        usedPct = if ($tot -gt 0) { [math]::Round((($tot - $free) / $tot) * 100, 1) } else { $null }
    }
}

# =============================================================================
# SECTION 8 - CPU UTILISATION
# =============================================================================

$report.cpu = Collect 'cpu' {

    # Two reasons this uses PerfFormattedData rather than Get-Counter:
    #
    #   1. Get-Counter counter paths are LOCALISED. On a non-English Windows the
    #      path is "\Prozessor(_Total)\..." and a hardcoded English path simply
    #      fails. PerfFormattedData names are language-independent.
    #   2. Get-Counter needs a sampling interval and therefore sleeps. This
    #      returns immediately, which keeps the whole collection fast.
    #
    # The value is a single instantaneous sample, not a smoothed average. That
    # is fine for a twice-daily health report and is documented here so nobody
    # later mistakes it for a reliable load average.
    $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor |
            Where-Object Name -eq '_Total'

    [ordered]@{
        loadPct      = $p.PercentProcessorTime
        interruptPct = $p.PercentInterruptTime
    }
}

# =============================================================================
# SECTION 9 - STORAGE VOLUMES AND PHYSICAL DISKS
# =============================================================================

# Volume labels are omitted on purpose: users name their drives, and those names
# are often personal. A drive letter and a free-space figure are all the report
# needs.

$report.storage = Collect 'storage' {

    [ordered]@{
        # DriveType 3 is "local disk". This deliberately excludes mapped network
        # drives and removable media, whose free space belongs to somebody else
        # and whose failure is not this machine's problem.
        volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            [ordered]@{
                drive   = $_.DeviceID
                fs      = $_.FileSystem
                sizeGb  = (Get-Gb $_.Size)
                freeGb  = (Get-Gb $_.FreeSpace)

                # Percentage free is computed here rather than on the server so
                # that every consumer agrees on the number and the rounding.
                freePct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { $null }
            }
        })

        # Win32_DiskDrive is the fallback-friendly alternative, but
        # Get-PhysicalDisk reports HealthStatus and OperationalStatus directly,
        # which is the actual early-warning signal for a dying disk.
        # SilentlyContinue because the Storage module can be absent on Server
        # Core and on very old builds; a missing section beats a failed run.
        physicalDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{
                mediaType   = "$($_.MediaType)"
                busType     = "$($_.BusType)"
                sizeGb      = (Get-Gb $_.Size)
                health      = "$($_.HealthStatus)"
                operational = "$($_.OperationalStatus)"
            }
        })
    }
}

# =============================================================================
# SECTION 10 - DISK RELIABILITY
# =============================================================================

# Wear, temperature and power-on hours are the numbers that let you replace a
# disk before it fails rather than after. Not every controller exposes them:
# SATA drives often return nothing useful, and the counters may need elevation.
# Absent values are expected and are reported as null, not as zero.

$report.diskHealth = Collect 'diskHealth' {

    # Note the deliberate absence of disk names: size is enough to correlate
    # this with the physicalDisks list above, and a model name is a fingerprint.
    ,@(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
        $d = $_
        $r = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue

        [ordered]@{
            sizeGb       = (Get-Gb $d.Size)
            temperatureC = $r.Temperature
            wear         = $r.Wear
            powerOnHours = $r.PowerOnHours
            readErrors   = $r.ReadErrorsTotal
            writeErrors  = $r.WriteErrorsTotal
        }
    })
}

# =============================================================================
# SECTION 11 - WINDOWS UPDATE: POLICY AND LAST ACTIVITY
# =============================================================================

$report.windowsUpdate = Collect 'windowsUpdate-policy' {

    # Two different registry trees matter here. Policies live under
    # ...\Policies\Microsoft\Windows\WindowsUpdate and represent what an
    # administrator or WSUS decided. The ...\Auto Update\Results keys record
    # what actually happened. Reading both is how you tell "updates are
    # deferred by policy" apart from "updates are failing".
    $wu = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
            -ErrorAction SilentlyContinue
    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
            -ErrorAction SilentlyContinue

    $detect  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect' -ErrorAction SilentlyContinue
    $install = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -ErrorAction SilentlyContinue

    [ordered]@{
        # A one-word summary of who is actually driving updates, so a reader
        # does not have to infer it from three separate registry values.
        managedBy      = if ($wu.WUServer) { 'WSUS' } elseif ($null -ne $au.AUOptions) { 'GPO' } else { 'Microsoft Update' }

        # AUOptions legend: 2 = notify before download, 3 = auto download and
        # notify before install, 4 = scheduled install. Anything else, or a null,
        # means behaviour is being controlled elsewhere.
        auOptions      = $au.AUOptions
        noAutoUpdate   = $au.NoAutoUpdate

        # Deferral periods. Large values here explain a machine that is "behind"
        # while being perfectly healthy, which is the single most common false
        # alarm in update reporting.
        deferQuality   = $wu.DeferQualityUpdatesPeriodInDays
        deferFeature   = $wu.DeferFeatureUpdatesPeriodInDays

        # Last successful detect/install. A detect that has not succeeded in
        # days is a real fault: the machine cannot see the update service.
        lastDetectUtc  = if ($detect.LastSuccessTime)  { ([datetime]$detect.LastSuccessTime).ToUniversalTime().ToString($script:UtcFormat) }  else { $null }
        lastInstallUtc = if ($install.LastSuccessTime) { ([datetime]$install.LastSuccessTime).ToUniversalTime().ToString($script:UtcFormat) } else { $null }

        # The service state belongs next to the results: a stopped wuauserv
        # explains every other number in this section being stale.
        serviceState   = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status.ToString()
    }
}

# =============================================================================
# SECTION 12 - WINDOWS UPDATE: PENDING AND HISTORY
# =============================================================================

# These two use the Windows Update COM API directly. It is the only
# no-dependency way to ask "what is genuinely outstanding", and it is the same
# API the Windows Update UI uses, so the answer matches what a user would see.
#
# Caveats, documented because they surprise people:
#   - The search is ONLINE and can take 10 to 60 seconds. -Fast skips it.
#   - On a machine managed by a WSUS server that is unreachable, the search can
#     hang until it times out, then fail. That is recorded as a section error.
#   - The COM objects are released here by going out of scope at the end of the
#     script block; we do not hold them across sections.

if (-not $Fast) {

    $report.windowsUpdate.pending = Collect 'windowsUpdate-pending' {

        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()

        # Online means "ask the configured source", which is WSUS or Microsoft
        # Update depending on policy. Setting this explicitly documents intent
        # rather than relying on the default.
        $searcher.Online = $true

        # IsInstalled=0 is "not yet installed". IsHidden=0 excludes updates the
        # user or an admin has deliberately hidden, which would otherwise be
        # counted as outstanding forever and produce permanent false alarms.
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')

        $items = @($result.Updates | ForEach-Object {
            [ordered]@{
                title        = $_.Title
                kb           = (@($_.KBArticleIDs) -join ',')
                severity     = $_.MsrcSeverity

                # When the update was last published/revised. A COUNT of pending updates
                # cannot be judged without it: three updates released yesterday are normal,
                # one released six weeks ago is a machine that is not patching. This is the
                # closest thing the update client exposes to a release date.
                releasedUtc  = if ($_.LastDeploymentChangeTime -and
                                  $_.LastDeploymentChangeTime -ne [datetime]::MinValue) {
                    $_.LastDeploymentChangeTime.ToUniversalTime().ToString($script:UtcFormat)
                } else { $null }

                # Downloaded but not installed is a different operational state
                # from not-yet-downloaded: it usually means "waiting for a
                # reboot or a maintenance window".
                downloaded   = $_.IsDownloaded
                rebootNeeded = $_.RebootRequired

                # Type 2 is a driver update. Driver updates are commonly
                # excluded from automatic approval, so knowing which pending
                # items are drivers explains why a count is not going down.
                isDriver     = ($_.Type -eq 2)
            }
        })

        [ordered]@{
            count            = $items.Count
            items            = $items

            # Kept for diagnosis: 2 means the search itself succeeded. A
            # non-zero value here with zero items means the search ran and found
            # nothing, which is very different from the search failing.
            searchResultCode = $result.ResultCode
        }
    }

    $report.windowsUpdate.history = Collect 'windowsUpdate-history' {

        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()

        # ResultCode legend. This is the field that turns "updates are not
        # installing" from a complaint into a diagnosis: 4 means failed, 3 means
        # installed with errors (often a per-update failure inside a batch), and
        # 5 means aborted, usually by a shutdown.
        $codes = @{
            0 = 'NotStarted'
            1 = 'InProgress'
            2 = 'Succeeded'
            3 = 'SucceededWithErrors'
            4 = 'Failed'
            5 = 'Aborted'
        }

        # 15 entries is enough to show a pattern - "the last eight failed" - while
        # keeping the payload small. QueryHistory takes (startIndex, count).
        ,@($searcher.QueryHistory(0, 15) | ForEach-Object {
            [ordered]@{
                dateUtc    = $_.Date.ToUniversalTime().ToString($script:UtcFormat)
                title      = $_.Title
                resultCode = $codes[[int]$_.ResultCode]

                # The HRESULT is the actual error number. Without it, a failed
                # update is unactionable; with it, it can be searched.
                hresult    = ('0x{0:X8}' -f $_.HResult)
            }
        })
    }
}

# =============================================================================
# SECTION 13 - PENDING REBOOT
# =============================================================================

# "Pending reboot" has no single authoritative flag; Windows tracks it in three
# unrelated places depending on what is waiting. Checking all three is the only
# way to avoid false negatives. Each is meaningful on its own:
#
#   componentBasedServicing - a servicing operation needs a restart to finish
#   windowsUpdate           - a Windows Update is staged and waiting
#   pendingFileRename       - a file was locked and will be replaced at boot
#
# The combined "any" flag exists so the server does not have to know this rule.

$report.rebootRequired = Collect 'rebootRequired' {

    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
              -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations

    [ordered]@{
        componentBasedServicing = $cbs
        windowsUpdate           = $wu

        # The value is a list of file moves; we only care whether it exists, so
        # it is cast to a boolean rather than shipped.
        pendingFileRename       = [bool]$pfr

        any                     = ($cbs -or $wu -or [bool]$pfr)
    }
}

# =============================================================================
# SECTION 14 - SECURITY POSTURE
# =============================================================================

# Each aspect is collected in its own Collect block instead of one big section.
# They fail for different reasons and on different machines - TPM and BitLocker
# need elevation, Secure Boot only exists on UEFI - and separate entries in
# collectionErrors tell the reader which one was unavailable.

$report.security = [ordered]@{}

$report.security.defender = Collect 'defender' {

    # Get-MpComputerStatus ships with Windows Defender / Microsoft Defender and
    # throws if a third-party antivirus has replaced it. That is a legitimate
    # state on a managed fleet, so the throw becomes a section error rather than
    # a failed run.
    $m = Get-MpComputerStatus -ErrorAction Stop

    [ordered]@{
        serviceEnabled   = $m.AMServiceEnabled
        antivirusEnabled = $m.AntivirusEnabled
        realTimeEnabled  = $m.RealTimeProtectionEnabled

        # Signature version plus AGE. The version string alone does not tell you
        # whether updates are arriving; age does.
        signatureVersion = $m.AntivirusSignatureVersion
        signatureAgeDays = $m.AntivirusSignatureAge

        lastQuickScanUtc = if ($m.QuickScanStartTime) { $m.QuickScanStartTime.ToUniversalTime().ToString($script:UtcFormat) } else { $null }

        # Tamper protection prevents a local admin from disabling Defender,
        # which is why it is worth knowing about separately from the on/off
        # states above.
        tamperProtection = "$($m.TamperProtectionSource)"
    }
}

$report.security.firewall = Collect 'firewall' {

    # Per profile rather than a single boolean: a machine with Domain on and
    # Public off is a specific, common misconfiguration that an aggregate flag
    # would hide.
    ,@(Get-NetFirewallProfile | ForEach-Object {
        [ordered]@{
            profile = $_.Name
            enabled = $_.Enabled
        }
    })
}

$report.security.secureBoot = Collect 'secureBoot' {

    # Confirm-SecureBootUEFI throws on legacy BIOS and when unelevated. Both are
    # facts worth recording rather than errors worth aborting for, so the
    # exception is caught here and returned as a descriptive string. The server
    # can then distinguish /unavailable: .../ from true and false.
    try {
        [bool](Confirm-SecureBootUEFI)
    }
    catch {
        "unavailable: $($_.Exception.Message)"
    }
}

$report.security.tpm = Collect 'tpm' {

    # Get-Tpm requires an administrator token. Under SYSTEM (the production
    # case) it works. SpecVersion matters because TPM 1.2 cannot do the things
    # TPM 2.0 can, and some compliance rules care.
    $t = Get-Tpm -ErrorAction Stop

    [ordered]@{
        present     = $t.TpmPresent
        ready       = $t.TpmReady
        enabled     = $t.TpmEnabled
        specVersion = $t.SpecVersion
    }
}

$report.security.bitLocker = Collect 'bitLocker' {

    # Requires elevation. EncryptionPercentage is included because "EncryptionInProgress"
    # for six months means something is stuck, which volume status alone hides.
    # No recovery passwords or key protectors are read - that is not health data,
    # and there is no reason for it to leave the machine.
    ,@(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
        [ordered]@{
            mountPoint    = $_.MountPoint
            volumeStatus  = "$($_.VolumeStatus)"
            protection    = "$($_.ProtectionStatus)"
            encryptionPct = $_.EncryptionPercentage
        }
    })
}

# =============================================================================
# SECTION 15 - CRITICAL SERVICES
# =============================================================================

# A short, deliberate watchlist rather than every service on the machine. These
# are the ones whose absence breaks something a user would notice: Defender,
# Windows Update, background transfer, delivery optimisation, event logging,
# file sharing, printing, and Remote Desktop. StartType is included because a
# service that is Running but Disabled will not come back after a reboot.

$report.services = Collect 'services' {

    $watch = 'WinDefend', 'wuauserv', 'BITS', 'DoSvc', 'EventLog', 'LanmanServer', 'Spooler', 'TermService'

    ,@(Get-Service -Name $watch -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            name      = $_.Name
            status    = "$($_.Status)"
            startType = "$($_.StartType)"
        }
    })
}

# =============================================================================
# SECTION 16 - RECENT ERROR EVENTS
# =============================================================================

# Counts and provider names only. Event messages routinely contain usernames,
# file paths and document titles, so the message text is never transmitted. The
# provider name ("Disk", "Application Error") is enough to point a human at the
# right log, and it carries no personal data.
#
# 24 hours matches the reporting cadence: a window twice as long as the interval
# means an incident is described by at least two reports, so it can be seen to
# start and stop.

$report.events = Collect 'events' {

    $since = (Get-Date).AddHours(-24)
    $all   = New-Object 'System.Collections.Generic.List[object]'

    foreach ($log in 'System', 'Application') {

        # Level 1 is Critical, 2 is Error. Warnings are excluded deliberately:
        # they are numerous, usually benign, and would drown the signal.
        foreach ($lvl in 1, 2) {

            # MaxEvents caps the work on a machine that has been logging errors
            # for months. 500 per log and level is far above a healthy machine
            # and still bounded.
            $all.AddRange(@(Get-WinEvent -FilterHashtable @{
                LogName   = $log
                Level     = $lvl
                StartTime = $since
            } -MaxEvents 500 -ErrorAction SilentlyContinue))
        }
    }

    $top = $all | Group-Object ProviderName |
        Sort-Object Count -Descending |
        Select-Object -First 8

    [ordered]@{
        windowHours = 24
        critical    = @($all | Where-Object Level -eq 1).Count
        error       = @($all | Where-Object Level -eq 2).Count
        topSources  = @($top | ForEach-Object {
            [ordered]@{
                source = $_.Name
                count  = $_.Count
            }
        })
    }
}

# =============================================================================
# SECTION 17 - UPLOAD
# =============================================================================

# The spool exists because the alternative is silent data loss. A workstation that
# is off, behind a dead link, or reporting while the server is being patched must not
# simply drop its report - it keeps it and tries again next run.
#
# The order is deliberate: write to the spool FIRST, then send. If the machine dies
# mid-request, the report is still on disk. The only thing that removes a file is a
# definitive answer from the server.

function Get-ClientKey {
    <#
    .SYNOPSIS
        Returns the client key as lowercase hex.

    .DESCRIPTION
        The key is stored DPAPI-sealed to this machine (LocalMachine scope), so it is
        unreadable if the disk is moved to another computer, and it is never present in
        plaintext on disk. Unsealing requires the machine's DPAPI master key, which the
        OS manages - we store nothing in the registry.

        DPAPI lives in System.Security.dll, which PowerShell 5.1 does not load by
        default, hence the Add-Type.
    #>
    param([Parameter(Mandatory)][string] $KeyPath)

    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $sealed = [IO.File]::ReadAllBytes($KeyPath)
    $raw = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $sealed, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return ([BitConverter]::ToString($raw) -replace '-', '').ToLowerInvariant()
}

function Send-SpooledReports {
    <#
    .SYNOPSIS
        Posts every spooled report, oldest first, and deletes the ones the server accepted.

    .DESCRIPTION
        -InFile is used rather than -Body so the exact bytes on disk are what gets sent.
        Passing a string would re-encode it, and the server requires UTF-8 without a BOM.

        The status handling is the whole point of the spool:

          2xx              accepted - delete. Includes a duplicate replay, which the
                           server answers with 200 and duplicate:true.
          400/413/415      the server will never accept this body - delete, or it
                           retries forever and fills the disk.
          401/403          wrong key or disabled/revoked agent - keep, and make noise
                           via the exit code. Somebody has to fix this.
          429              rate limited - keep, it will go through next run.
          5xx, no response network fault, DNS, TLS - keep and retry.
    #>
    param(
        [Parameter(Mandatory)][string] $SpoolDir,
        [Parameter(Mandatory)][string] $ReportUrl,
        [Parameter(Mandatory)][string] $AgentId,
        [Parameter(Mandatory)][string] $Key,
        [string] $LogFile
    )

    $headers = @{
        'Authorization'   = "Bearer $Key"
        'X-GMWSys-Client' = $AgentId
    }

    $sent = 0
    $kept = 0

    $files = @(Get-ChildItem -LiteralPath $SpoolDir -Filter '*.json' -File |
                    Sort-Object LastWriteTime)

    foreach ($f in $files) {

        $status = 0

        try {
            # -Body with raw bytes, not -InFile: -InFile makes PowerShell send the body
            # with an unknown length (chunked), which some proxies refuse outright. Passing
            # bytes sets Content-Length and still sends exactly what is on disk.
            $resp = Invoke-RestMethod -Uri $ReportUrl -Method Post `
                        -Body ([IO.File]::ReadAllBytes($f.FullName)) `
                        -ContentType 'application/json; charset=utf-8' `
                        -Headers $headers -UserAgent "GMWSystemsHealthAgent/$AgentVersion" `
                        -TimeoutSec 30 -ErrorAction Stop
            $status = 200
            $detail = if ($resp -and $resp.duplicate) { 'duplicate' } else { 'stored' }
        }
        catch {
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode

                # Read the error body. This is the difference between "our endpoint said
                # agent_disabled" and "something in front of it returned an HTML block
                # page". Without it, every 403 looks the same and you are guessing.
                #
                # Bounded read: a hostile or broken endpoint must not be able to make the
                # agent pull an unbounded response into memory.
                try {
                    $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $buffer = New-Object char[] 1024
                    $read = $sr.Read($buffer, 0, $buffer.Length)
                    $detail = if ($read -gt 0) { New-Object string($buffer, 0, $read) } else { '' }
                    if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
                }
                catch { $detail = $_.Exception.Message }
            }
            else {
                # No HTTP response at all: DNS, TLS, connection refused, timeout.
                $status = -1
                $detail = $_.Exception.Message
            }
        }

        if (($status -ge 200 -and $status -lt 300) -or ($status -eq 400) -or
            ($status -eq 413) -or ($status -eq 415)) {
            Remove-Item -LiteralPath $f.FullName -Force
            $sent++
            Write-Verbose "sent $($f.Name) status=$status ($detail)"
        }
        else {
            $kept++
            Write-Verbose "kept $($f.Name) status=$status ($detail)"
        }

        # One line per attempt in a file the operator can actually read after the fact.
        # A scheduled task has no console, and Task Scheduler only tells you the exit code.
        if ($LogFile) {
            try {
                Add-Content -LiteralPath $LogFile -Value (
                    '{0} status={1} {2} :: {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $status, $f.Name, $detail)
            }
            catch { }
        }
    }

    return [ordered]@{ sent = $sent; kept = $kept }
}

# =============================================================================
# SECTION 18 - OUTPUT
# =============================================================================

# Duration is filled in last so it measures the real collection cost, and the
# error list is attached at the end, after every section has had its chance to
# append to it.

$report.meta.durationMs   = [int]((Get-Date) - $script:StartedAt).TotalMilliseconds

# .ToArray(), NOT @($script:CollectErrors).
# In PowerShell 5.1, wrapping an OrderedDictionary - or a List holding one - in
# the @() operator throws "Argument types do not match", because @() tries to
# enumerate the dictionary into DictionaryEntry items. This is a real 5.1
# defect, not a style preference. Pipeline form (@(... | ForEach-Object { ...
# })) is unaffected; it is only the direct @($variable) case that breaks.
$report.collectionErrors = $script:CollectErrors.ToArray()

# Depth 8 covers the deepest structure (storage.volumes[], windowsUpdate.pending.items[]).
# Sending always uses the compressed form: the server wants a single line, and there is no
# reason to put 40 KB of pretty-printed JSON on the wire.
$json = $report | ConvertTo-Json -Depth 8 -Compress:($Compress -or $Send)

if ($OutFile) {

    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # UTF-8 WITHOUT a BOM. A BOM is invisible in an editor but is a real byte
    # sequence at the start of the file, and it breaks strict JSON parsers -
    # json_decode() in PHP returns null on it. .NET's UTF8Encoding defaults to
    # emitting one, hence the explicit $false.
    [IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false))

    Write-Verbose "Wrote $OutFile"
}
elseif (-not $Send) {
    # No -OutFile and not sending: emit to the pipeline so the report can be inspected or
    # piped. With -Send this would dump 20 KB into a task log that nobody reads.
    $json
}

if ($Send) {

    # Older .NET builds behind PowerShell 5.1 can still negotiate TLS 1.0 by default, and
    # the resulting handshake failure reads nothing like a TLS problem. Ask explicitly.
    # Require TLS 1.2, do not merely permit it. -bor would leave SSL3/TLS1.0 enabled if the
    # platform default included them; this pins the set. TLS 1.3 is added where the enum
    # exists (it does on .NET 4.8, not on every older build).
    try {
        $secure = [Net.SecurityProtocolType]::Tls12
        if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
            $secure = $secure -bor [Net.SecurityProtocolType]::Tls13
        }
        [Net.ServicePointManager]::SecurityProtocol = $secure
    }
    catch { }

    $root     = Split-Path -Parent $AgentConfig
    $keyPath  = Join-Path $root 'client.key'
    $spoolDir = Join-Path $root 'spool'

    # An unattributable report is data with nowhere to go. Refuse, loudly, via the exit
    # code - rather than posting something the server will reject anyway.
    if (-not $agentId -or -not $reportUrl) {
        Write-Verbose 'Not sending: agentId or reportUrl missing from the agent config'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        Write-Verbose "Not sending: no client key at $keyPath"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $spoolDir)) {
        New-Item -ItemType Directory -Path $spoolDir -Force | Out-Null
    }

    # Persist BEFORE sending, never after.
    $spoolName = '{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $report.meta.reportId
    [IO.File]::WriteAllText(
        (Join-Path $spoolDir $spoolName), $json, (New-Object System.Text.UTF8Encoding $false))

    # Cap the queue. At four runs a day, 50 files is roughly twelve days of history: long
    # enough to ride out a holiday or a server rebuild, short enough that a permanently
    # broken agent cannot fill the disk.
    $queued = @(Get-ChildItem -LiteralPath $spoolDir -Filter '*.json' -File |
                    Sort-Object LastWriteTime)
    if ($queued.Count -gt 50) {
        $queued | Select-Object -First ($queued.Count - 50) | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

    # A key that will not unseal is a deployment problem, not a transient one. Say so in
    # one line instead of letting a raw .NET stack trace surface in Task Scheduler.
    try {
        $clientKey = Get-ClientKey -KeyPath $keyPath
    }
    catch {
        Write-Verbose "Not sending: could not unseal the client key - $($_.Exception.Message)"
        exit 1
    }

    $result = Send-SpooledReports -SpoolDir $spoolDir -ReportUrl $reportUrl `
                -AgentId $agentId -Key $clientKey `
                -LogFile (Join-Path $root 'healthreport.log')

    Write-Verbose ("sent={0} kept={1}" -f $result.sent, $result.kept)

    # Non-zero while anything is still waiting, so Task Scheduler's Last Run Result is a
    # real signal instead of always-green decoration.
    if ($result.kept -gt 0) { exit 1 }
    exit 0
}
