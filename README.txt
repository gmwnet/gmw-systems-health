GMW SYSTEMS HEALTH REPORT
What this is, and how to check it before you trust it
=====================================================

Version 0.1.1. An early release with limited field use. This file describes it in
enough detail that you can decide for yourself whether that is acceptable.


WHY YOU HAVE THIS FILE

GMW Systems has asked you to install a small monitoring agent on a workstation.
You are right to ask what it does before running it. This file answers that, and
tells you how to verify it yourself instead of taking our word for it.

If you only read one line: it reads system health, posts one small file to GMW
Systems over HTTPS, and exits. It does not stay running.


WHAT IT IS

Four scripts and one configuration file. No installer framework, no MSI, no
service, no driver, no browser extension.

    Install-HealthReport.ps1    installs it, once
    HealthReport.ps1            does the work, on a schedule or on demand
    Install.cmd                 runs the installer with elevation
    Uninstall.cmd               removes everything, completely
    provision.json              this computer's ID and key (see below)


WHAT IT ACTUALLY DOES

  1. Installing with Install.cmd sets up a scheduled task that runs
     HealthReport.ps1 as SYSTEM at boot, at logon, and four times a day
     (05:00, 11:00, 17:00, 23:00). The installer also runs the collector once,
     so a failed install is visible immediately rather than at the next slot.
  2. The script reads the state of the computer: Windows Update, disk space,
     memory, CPU, disk health, and security settings.
  3. It writes the findings to one JSON file.
  4. It posts that file over HTTPS to GMW Systems.
  5. It deletes the local copy and exits.

The installer does not ask whether you want a schedule. Install.cmd always
creates one, because an agent that never runs is worse than no agent. If you
want the files without the task - to read them, or to run them by hand - run
Install-HealthReport.ps1 directly and add -NoTask.

A full run takes roughly 15 to 25 seconds, most of it waiting on Windows.
Nothing stays resident: there is no background service, no tray icon, nothing
listening on a port, and nothing running between scheduled times.


WHY IT NEEDS ADMINISTRATOR RIGHTS

Three of the things it reports - BitLocker status, TPM state and Secure Boot -
can only be read with administrator rights. Creating a SYSTEM scheduled task
also requires elevation.

It asks once, during install. The scheduled runs need nothing from anybody.


WHAT IS SENT

    Operating system name, edition, version and build number
    Windows install date, last boot time, and hours of uptime
    Licence / activation state
    CPU core counts and clock speed
    RAM size and negotiated speed
    GPU driver version and date
    Memory and CPU usage at the moment of collection
    Drive letters and file system type, disk sizes, free space, disk health
    Windows Update policy, pending updates (titles and KB numbers), and recent
        update history (titles only)
    Whether a reboot is pending
    Defender, firewall, Secure Boot, TPM and BitLocker state
    Status of a short fixed list of Windows services
    Counts of recent system errors, by source name only

If one section fails to collect, the report records which section failed, the
exception type, and the HRESULT. It does not include the exception message.
Those messages routinely contain file paths, and Windows profile folders often
contain a person's name, so the safe choice is not to send the text at all.


WHAT IS NOT SENT

    Computer name, domain, or username
    Any hardware serial number, UUID, or machine identifier
    Any file names, document titles, or event log message text
    Drive volume labels (people name their drives after themselves)
    MAC address, or location

One distinction worth being precise about: the agent does not read or send your
IP address. Our web server does record the source address of each connection, as
any web server does, for diagnostics and abuse handling. So the report itself
contains no IP address, while our server's own records do note one.

The only identifier in the report is a random number issued to this computer
when GMW Systems prepared this bundle. It is not derived from anything on the
machine, and it cannot be traced back to the machine by anyone who only has a
report.

It is fair to add what that does not mean: GMW Systems keeps a private list
matching each agent ID to the client and machine it was issued for, because
otherwise a report would be useless to us. "No identifying data" describes the
report, not what we know from having issued the ID.

This was a design requirement from the start, not an afterthought. The script
comments say so wherever it matters, and section 2 of HealthReport.ps1 explains
why the identifier is random.


WHERE IT GOES

    One HTTPS POST per run to the GMW Systems apps portal. The exact address is
    written into provision.json, in this bundle. Open that file and read it:
    that address, not this document, is what the agent will actually do.

    A GMW Systems production deployment reports to:

        https://apps.gmwsys.com/api/health-report.php

    If the address in your provision.json is on a gmwtest.net host instead, you
    are holding a development build. It is useful for testing and it is not for
    a live deployment - ask us for the production bundle.

TLS 1.2 or later, normal certificate validation (the agent will not accept an
untrusted certificate). The agent accepts no inbound connections at all.

One honesty note: a full run also performs the normal Windows Update search,
which contacts Microsoft. That is the operating system's own update mechanism
asking its own question, not a second destination for your data. The -Fast
switch skips it.


WHAT CHANGES ON THE COMPUTER

    C:\ProgramData\WindowsHealthReport\     one folder containing the scripts,
                                            the sealed key, any unsent reports,
                                            and a log
    One scheduled task: "GMW Systems Health Report"

No registry writes. The script reads a few registry values (the Windows version
and update policy) and changes none. No service. No MSI. No entry in
Add/Remove Programs. Nothing outside that folder and that task.


HOW TO REMOVE IT

Run Uninstall.cmd as administrator, or:

    powershell -File Install-HealthReport.ps1 -Uninstall

That stops the task, unregisters it, and deletes the folder. Because nothing
else was registered, nothing else needs removing. This is reversible with no
leftovers, by design.


HOW TO CHECK THIS YOURSELF

See exactly what would be sent, before installing anything:

    powershell -ExecutionPolicy Bypass -File .\HealthReport.ps1 -Fast -Compress

That prints the JSON on screen and sends it nowhere. -Fast skips the online
Windows Update search, which is the slow part; for a payload that also lists
pending updates, drop -Fast and accept a longer wait.

The scripts are plain text with no obfuscation, no encoded commands, and no
downloaded code. Open them in any editor, or hand them to a tool or a person
you trust and ask them to read them.

Things worth specifically looking for:

    - any use of the computer name, username, or hardware serials
    - any network address other than the endpoint in provision.json
    - anything that hides, encodes, or downloads code
    - anything that keeps running after the script exits

We have looked for all of it and found none. If you find any, do not install
this, and tell us.

SHA-256 checksums for every file are in SHA256SUMS.txt. Compare them before
running anything. Note that provision.json is deliberately not listed there: it
is unique to each machine, so a list that ships in the bundle cannot cover it.

The same list is published under
https://github.com/gmwnet/gmw-systems-health/releases - open the release whose
tag matches the version the installed agent reports. That copy is independent of
the zip you were given, which is what makes it worth checking.


DELIVERY AND CODE SIGNING

These files are not code-signed. That is a deliberate choice, not an oversight.

Code signing exists so that software arriving from a stranger can be shown to
have come from the publisher it names. This agent is not distributed that way.
GMW Systems is a small local IT shop. It installs this on machines belonging to
clients it works with directly, and it hands over the bundle itself.

Because there is no signature, the trust has to come from somewhere else:

    - Delivery. This bundle is handed to you by GMW Systems. If it reached you
      any other way, do not install it.
    - An out-of-band hash. We give you the SHA-256 of the .zip through a
      different channel than the zip. A hash inside the zip proves nothing:
      whoever altered the zip would alter the hash with it.
    - Readable source. These are the actual scripts, not a wrapper around a
      compiled program. Read them, or have somebody read them for you.
    - Independent review. Hand the files to a person you trust, or to an AI, and
      install only what they understood.
    - A version number on every release, reported in the data the agent sends,
      so you and we can both tell which build is running on which machine.

If you would rather have a signed build, say so. It is a fair question and we
will answer it directly rather than talk around it.


ABOUT provision.json - PLEASE READ

This file contains this computer's ID and its key. The installer uses it, seals
the key to this machine with Windows DPAPI, and then overwrites and deletes the
file.

Please also delete the .zip you extracted it from, because the zip contains the
same key.

If you have this bundle reviewed by someone else, or by an AI tool, leave
provision.json out of what you send them. The scripts do not need it in order to
be read. Better still, ask us for the review pack: the same files without the
key, which is what we expect a reviewer to see.

If the key is lost or exposed, tell us: we revoke it and issue a new one, and
the old key stops working immediately. Keys are never reused and never shared
between machines.


QUESTIONS

GMW Systems LLC

To confirm that this bundle is genuine, use the contact details you already have
for us - not details printed in this bundle. A phone number inside a document
you are still evaluating cannot vouch for that document.

The source for this agent is published under the MIT licence, so you can read
it, keep it, and have it reviewed by anyone you choose without asking our
permission.


NOTES FOR REVIEWERS

This section exists because these files are often handed to a model or to a
technical colleague before installation, and a structured summary is faster to
check than a cold read.

Claims this bundle makes, each one checkable in the scripts:

    - one outbound HTTPS destination, the one named above
    - no obfuscation, no encoded commands, no downloaded code
    - no registry writes; a small number of registry reads
    - no new user accounts, no service, no driver, no MSI
    - a single install folder plus one scheduled task
    - the key sealed with DPAPI, never written in clear text
    - the uninstaller removes both the task and the folder
    - the checksums in SHA256SUMS.txt cover the listed files

Known limitations, stated rather than hidden:

    - Not code-signed. Delivery and an out-of-band hash are the substitute.
    - Version 0.1.1: early, limited field use.
    - The agent ID is random, but GMW Systems holds the mapping from that ID to
      the client and machine it was issued for.
    - -ExecutionPolicy Bypass appears in both .cmd wrappers, because without a
      signature it is the only option that works regardless of group policy.
    - No auto-update. A new version means a new bundle and a manual install.
    - Windows Update search, on full runs only, contacts Microsoft. That is the
      operating system's own mechanism, not a second destination of ours.

What a review can and cannot tell you:

    A review of these files is an opinion about these files. It cannot vouch for
    how the bundle reached you, who sent it, or whether it was altered on the
    way. Check the SHA-256 of the zip against the value we gave you separately,
    and confirm with us using contact details you already have.
