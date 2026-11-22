GMW SYSTEMS HEALTH REPORT
What this is, and how to check it before you trust it
=====================================================

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
    HealthReport.ps1            does the work, on a schedule
    Install.cmd                 runs the installer with elevation
    Uninstall.cmd               removes everything, completely
    provision.json              this computer's ID and key (see below)


WHAT IT ACTUALLY DOES

  1. A scheduled task runs HealthReport.ps1 as SYSTEM when the computer boots,
     when a user logs on, and four times a day (05:00, 11:00, 17:00, 23:00).
  2. The script reads the state of the computer: Windows Update, disk space,
     memory, CPU, disk health, and security settings.
  3. It writes the findings to one JSON file.
  4. It posts that file over HTTPS to GMW Systems.
  5. It deletes the local copy and exits.

A full run takes about 23 seconds, most of it waiting on Windows. Nothing stays
resident: there is no background service, no tray icon, nothing listening on a
port, and nothing running between scheduled times.


WHY IT NEEDS ADMINISTRATOR RIGHTS

Three of the things it reports - BitLocker status, TPM state and Secure Boot -
can only be read with administrator rights. Creating a SYSTEM scheduled task
also requires elevation.

It asks once, during install. The scheduled runs need nothing from anybody.


WHAT IS SENT

    Operating system name, edition, version and build number
    Licence / activation state
    CPU core counts and clock speed
    RAM size and negotiated speed
    GPU driver version and date
    Memory and CPU usage at the moment of collection
    Disk sizes, free space, and disk health
    Windows Update policy, pending updates, and recent update history
    Whether a reboot is pending
    Defender, firewall, Secure Boot, TPM and BitLocker state
    Status of a short fixed list of Windows services
    Counts of recent system errors, by source name only


WHAT IS NOT SENT

    Computer name, domain, or username
    Any hardware serial number, UUID, or machine identifier
    Any file names, document titles, or event log message text
    MAC address, or location

One distinction worth being precise about: the agent does not read or send your IP
address. Our web server does record the source address of each connection, as any
web server does, for diagnostics and abuse handling. So the report itself contains
no IP address, while our server's own records do note one.

The only identifier is a random number issued to this computer when GMW Systems
prepared this bundle. It is not derived from anything on the machine, and it
cannot be traced back to the machine by anyone who only has a report.

This was a design requirement from the start, not an afterthought. The script
comments say so wherever it matters, and section 2 of HealthReport.ps1 explains
why the identifier is random.


WHERE IT GOES

    One HTTPS POST to the GMW Systems apps portal. The exact endpoint URL is in
    provision.json (the configuration file in this bundle), so you can read it
    before running anything.

One outbound HTTPS connection per run, TLS 1.2 or later, normal certificate
validation (the agent will not accept an untrusted certificate). The agent
accepts no inbound connections at all.


WHAT CHANGES ON THE COMPUTER

    C:\ProgramData\WindowsHealthReport\     one folder containing the scripts,
                                            the sealed key, any unsent reports,
                                            and a log
    One scheduled task: "GMW Systems Health Report"

No registry keys. No service. No MSI. No entry in Add/Remove Programs. Nothing
outside that folder and that task.


HOW TO REMOVE IT

Run Uninstall.cmd as administrator, or:

    powershell -File Install-HealthReport.ps1 -Uninstall

That stops the task, unregisters it, and deletes the folder. Because nothing
else was registered, nothing else needs removing. This is reversible with no
leftovers, by design.


HOW TO CHECK THIS YOURSELF

Do not take our word for any of it. The scripts are plain text with no
obfuscation, no encoded commands, and no downloaded code. Open them in any
editor, or hand them to a tool or a person you trust and ask them to read them.

Things worth specifically looking for:

    - any use of the computer name, username, or hardware serials
    - any network address other than the endpoint in provision.json
    - anything that hides, encodes, or downloads code
    - anything that keeps running after the script exits

There is none of that. If you find any of it, do not install this, and tell us.

SHA-256 checksums for every file are in SHA256SUMS.txt. Compare them before
running anything.

The same list is published under
https://github.com/gmwnet/gmw-systems-health/releases — open the release whose tag
matches the version the installed agent reports.


ABOUT CODE SIGNING

These files are not code-signed. That is a deliberate choice, not an oversight.

Code signing exists so that software arriving from a stranger can be trusted to have
come from the publisher it claims. This agent is not distributed that way. GMW Systems
is a small local IT shop. It installs this on machines belonging to clients it works
with directly and in person. You know who gave you this file, because you spoke to
them.

We would rather say that plainly than buy a certificate and imply a formality that does
not match how this is delivered.

What we offer instead:

    - The complete source. These are the actual scripts, not a wrapper around a
      compiled program. Read them, or have somebody read them for you.
    - A version number on every release, reported in the data the agent sends, so
      you and we can both tell which build is running on which machine.
    - SHA-256 checksums for every file, available independently of the bundle, so
      you can confirm that what you received is what we sent.

If you would rather have a signed build, say so. It is a fair question and we will
answer it directly rather than talk around it.


ABOUT provision.json - PLEASE READ

This file contains this computer's ID and its key. The installer uses it, seals
the key to this machine with Windows DPAPI, and then overwrites and deletes the
file.

Please also delete the .zip you extracted it from, because the zip contains the
same key.

If the key is lost or exposed, tell us: we revoke it and issue a new one, and
the old key stops working immediately. Keys are never reused and never shared
between machines.


QUESTIONS

GMW Systems LLC
425-320-5823

The source for this agent is published under the MIT licence, so you can read it, keep
it, and have it reviewed by anyone you choose without asking our permission.
