Unified host-pushover v2.0 absorbs the legacy DSM variant into the same script
used on Debian, Raspberry Pi OS, and Ubuntu.

- Automatic platform detection preserves system-wide and DSM per-user
  configuration layouts, permissions, and caller overrides.
- DSM scheduler home discovery, transport retries, offline version reporting,
  and explicit health check-ins are included.
- Daily update discovery uses a small manifest and conditional HTTP requests.
  Notification delivery never waits for GitHub.
- Root must explicitly invoke `--update` to install verified release code.
  Updates preserve script ownership/mode, back up the old script, and replace it
  atomically. `--rollback` restores the recorded backup.
- A generated bootstrap migrates both legacy lineages, including `2.03-dsm`,
  without executing the old script or rewriting Pushover configuration.
- Dry-run, pinned releases, and local release bundles support staged rollout.

Before publishing this draft as stable, complete the real-device pilot in
`docs/ROLLOUT.md`. Automated tests exercise isolated GNU/BusyBox environments;
they do not establish compatibility with an untested NAS firmware or scheduler.
