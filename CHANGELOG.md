# Changelog

Versions follow the tag in this repository, and `$AgentVersion` in `HealthReport.ps1`
must match the tag exactly. The release workflow fails the build if they diverge, so the
number a client sees in a report is the version they actually have.

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
