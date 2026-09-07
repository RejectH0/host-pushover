# TODO

Version `2.1.0` adds update notices, local diagnostics, and readable update status.
Device validation and deployment records are maintained privately.
See [docs/ROLLOUT.md](docs/ROLLOUT.md).

## Completed

- [x] Add update notices with per-version deduplication, quiet delivery, safe DSM
  account switching, and retry eligibility independent of discovery success.
- [x] Add offline `--doctor` checks without sourcing configuration.
- [x] Add readable update status with UTC dates and sanitized failure history.
- [x] Move development into a normal user's workspace, preserve the original
  source for recovery, and replace the legacy remote/SSH configuration.
- [x] Connect the public GitHub repository using a dedicated SSH key and public
  commit attribution, keeping private deployment information outside Git.
- [x] Consolidate system and DSM notification behavior into one runtime script.
- [x] Retire the separate DSM development directory, retaining a private recovery archive.
- [x] Preserve configuration paths, contents, modes, precedence, setup flow, and
  existing notification invocation paths.
- [x] Retain DSM scheduler home discovery, transport retries, and health checks.
- [x] Provide offline version reporting and resolved profile/path diagnostics.
- [x] Adopt unified `2.0.0` versioning with explicit legacy-lineage migration.
- [x] Implement small-manifest GitHub discovery, conditional requests, daily
  caching, error backoff, update status, and a persistent availability flag.
- [x] Keep GitHub requests outside notification delivery.
- [x] Require explicit root installation with fresh metadata, integrity checks,
  locking, backups, atomic replacement, ownership/mode preservation, and rollback.
- [x] Generate the legacy bootstrap from the same updater code, with dry-run,
  pinned releases, offline bundles, and safe repeated invocation.
- [x] Provide root-owned checkers, idempotent cron setup, and DSM task instructions.
- [x] Fix response parsing, command-mode exclusivity, backup timestamp handling,
  and dependency reporting.
- [x] Add release tooling, draft publication workflow, and GNU/BusyBox tests.
- [x] Keep usage in README, completed changes in CHANGELOG, and plans here.
- [x] Add clearly marked personal maintainer migration tools, require wrapper
  opt-in, and check the generated bootstrap against the shared source in CI.
- [x] Provide migration prerelease publication for direct HTTPS downloads,
  avoiding per-device SSH setup while retaining the separate stable channel.
- [x] Publish reviewed version tags through CI, attach the standalone manifest,
  and check the public discovery endpoint before release workflow success.

## Release validation and rollout

- [ ] Confirm real-device execution on each supported deployment: system hosts,
  Raspberry Pi OS, Ubuntu, and both DSM NASes.
- [ ] On DSM, verify the actual Task Scheduler execution UID, resolved home,
  Bash/curl/tool capabilities, and a run with HOME absent.
- [ ] Pilot a local release bundle, compare configuration hashes and metadata,
  run intentional notification check-ins, and rehearse rollback.
- [ ] Confirm the daily check is active on each pilot. DSM needs a separate
  daily root task using the command printed by the installer.
- [x] Publish stable v2.0 with reviewed assets after CI and pilot sign-off.
- [ ] Confirm repository release immutability is enabled where available.
- [x] Verify conditional HTTP behavior against the actual published release
  endpoint: both 200 and 304 responses confirmed.
- [ ] Roll out the pinned stable release and record each device's results in a
  private inventory outside Git.

## Future work

- [ ] Independent manifest signature verification and a signing-key rotation
  process if supported by available deployment tools.
- [ ] Fleet inventory/reporting beyond the local upgrade output.
- [ ] Additional scheduler integrations if automatic cron setup and the printed
  daily-task command do not cover a future platform.

Every future change requires the same publication review: no real credentials,
private identities/addresses/paths, SSH keys, or deployment records in source,
documentation, tests, artifacts, or commit metadata.
