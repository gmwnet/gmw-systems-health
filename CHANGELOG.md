# Changelog

Versions follow the tag in this repository, and `$AgentVersion` in `HealthReport.ps1`
must match the tag exactly. The release workflow fails the build if they diverge, so the
number a client sees in a report is the version they actually have.

## 0.1.3 - 2026-11-22

Schema fix, found by comparing two machines' reports.

- A section that returns an array now stays an array on the wire. PowerShell unrolls an
  array returned from a function, so `security.bitLocker` serialised as an **object** on a
  machine with one volume and an **array** on a machine with two - one field, two types, and
  the single-volume case is the common one. Fixed in `Collect` with `-NoEnumerate`, which
  covers every array-valued section at once rather than patching the field that happened to
  show it.
- Consequence also fixed: an **empty** array used to unroll to nothing and become `null`, so
  "no volumes" and "collection failed" were indistinguishable. They are now `[]` and `null`.
- README: the manual uninstall command now includes `-ExecutionPolicy Bypass`. Without it the
  documented command fails on a stock Windows machine, where the default policy is
  `Restricted` and refuses any .ps1. `Uninstall.cmd` already passed it; the prose did not.
- No new network destinations, no new data, no change to what is collected.

## 0.1.2 - 2026-11-22

Second review, this time of the README against the scripts.

- `collectionErrors` no longer carries the exception message. 0.1.1 replaced path-like
  substrings with `<path>`, but the pattern stopped at the first space, so
  `C:\Users\Jane Smith\AppData\...` came out as `<path> Smith\AppData\...` - a name
  fragment. Rather than widen a regex that cannot be trusted to catch every shape of path,
  the text is not sent at all. The report records the section, the exception type and the
  HRESULT.
- README: the endpoint section no longer presents the production address as the one this
  bundle uses. It told the reader to stop if `provision.json` disagreed, which is exactly
  what a development bundle does. The section now names the production address for
  production deployments and states that a `gmwtest.net` address means a development build.

## 0.1.1 - 2026-11-22

Scheduling fix, found by an independent review of a bundle before it was installed.

- The installer now registers the SYSTEM scheduled task by default. Registering it used to
  require an explicit `-Task`, which `Install.cmd` never passed, so a bundle installed
  through the documented path proved one report and then never ran again. On the server
  that is indistinguishable from a healthy machine. `-Task` is still accepted; `-NoTask`
  provisions without a task, for inspecting an install by hand.
- `Install.cmd` now passes `-Task` explicitly as well, so the documented path schedules even
  if the installer default ever changes back.
- No collector logic change other than diagnostics: a failed section now reports a message
  with local file paths replaced by `<path>` and truncated to 200 characters. Exception
  messages can carry profile paths, and that field is the only free text in the report.
- `$AgentVersion` moves so a report shows which build a machine is running.

## 0.1.0 - 2026-11-22

First working agent.

- Collector covering OS and build (UBR), activation, hardware capability, memory, CPU,
  storage and volume free space, disk reliability counters, Windows Update policy plus
  pending updates and 15-entry history, pending-reboot flags, Defender/firewall/Secure
  Boot/TPM/BitLocker, a fixed service watchlist, and 24-hour system error counts by
  provider name only.
- Read-only. Collects and reports; changes nothing. No thresholds and no verdicts - those
  belong on the server so they can be corrected without redeploying a fleet.
- Privacy: the only identifier transmitted is a random GUID issued at registration. No
  computer name, username, domain, hardware serial, UUID, machine GUID, model name, volume
  label or timezone. Event log text is never transmitted, only provider names.
- One JSON document per run, UTF-8 without a BOM, single-line, all timestamps at second
  precision in `yyyy-MM-ddTHH:mm:ssZ`.
- Spool: a report is written to disk before the POST and deleted only on a 2xx, so an
  outage, a reboot or a crash cannot lose data. 400/413/415 discard; 401/403/429/5xx and
  network failures retain. Capped at 50 files.
- Runs as a scheduled task, never a service. Nothing stays resident, nothing listens on a
  port, and removal is: stop the task, delete the folder.
- Installer provisions from a server-minted bundle, seals the key with DPAPI to the local
  machine, hardens the install folder to SYSTEM + Administrators, self-checks, wipes and
  deletes the provisioning file, and optionally registers the SYSTEM task.
- No registry keys, no MSI, no service registration, no Add/Remove Programs entry.
