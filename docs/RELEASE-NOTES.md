host-pushover v2.2.0 bounds script backup accumulation while keeping offline rollback.

- Updates performed by this version retain the backup referenced by the rollback
  record and prune superseded managed script backups only after successful
  installation, checker setup, and local integrity verification.
- New root-only --prune-backups and --prune-backups --dry-run commands provide
  offline cleanup and a preview of eligible files and bytes.
- The recorded backup is protected regardless of age. Inconsistent recovery or
  installed state prevents deletion; unexpected files and links are skipped.
- Failed installations and update dry runs preserve all backups. Configuration
  backups and active updater files are outside the cleanup scope.

Both v2.0.0 and v2.1.0 can upgrade directly to this release. An older updater
cannot apply the new retention policy during its first installation of v2.2.0.
After that update, run --prune-backups --dry-run and then --prune-backups using
the newly installed script as root to remove accumulated backups. Subsequent
updates perform retention automatically. See README.md and docs/ROLLOUT.md for
the complete command sequence.

The existing configuration, daily task commands, version comparison, and
four-field manifest remain compatible. Hosts already running v2.1.0 can send
an update-available notice for this release; v2.0.0 uses its original flag/status.
Installation continues to require an explicit root --update invocation.

The standalone manifest is attached to this release and published through:
https://github.com/RejectH0/host-pushover/releases/latest/download/update-manifest.txt

Follow docs/ROLLOUT.md for deployment and rollback instructions.
