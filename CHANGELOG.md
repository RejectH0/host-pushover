# Changelog

## 2.0.0 - 2026-09-07

### Added

- One runtime script for Debian, Raspberry Pi OS, Ubuntu, and Synology DSM.
- Automatic platform detection and UID-based DSM home discovery, with explicit
  profile and resolved-path diagnostics when needed.
- Shared offline `--version` and explicit `--check-in` commands.
- Small-manifest GitHub release discovery, conditional requests, daily caching,
  bounded failure backoff, cached status, and a persistent update-available flag.
- Explicit root-only updates with fresh metadata, verified HTTPS downloads,
  SHA-256/version/syntax checks, backups, preserved ownership/modes, locking,
  atomic replacement, and rollback.
- A generated bootstrap using the same updater implementation to migrate legacy
  system and DSM releases, including the separate `2.03-dsm` lineage.
- Dry-run, pinned releases, offline pilot bundles, local-edit detection, and
  root-owned scheduled checkers. Bootstrap configures cron where available and
  prints a daily-task command for DSM or another scheduler.
- Release builder, draft-release workflow, isolated runtime/update tests, and a
  Debian/Ubuntu CI matrix with BusyBox update coverage.
- A prominently marked directory for RejectH0's personal migration tools, with
  a generated bootstrap, explicit-opt-in execution wrapper, and reproducible
  local upgrade archives that omit local owner metadata.
- CI-gated migration prereleases with public HTTPS downloads of the archive and
  execution wrapper, plus upgrade tarballs attached to future stable drafts.
- Version-tag publication of stable releases with a separately downloadable
  update manifest and a live discovery check before workflow success.

### Preserved

- Existing configuration paths, schema, setup questionnaire, permissions,
  override precedence, callers, and quiet successful delivery.
- DSM transient-failure retries and their optional configuration variables;
  system-profile transport still defaults to one attempt.
- Root updates do not source or rewrite notification configuration.

### Fixed

- Exact top-level JSON success parsing, including malformed/ambiguous responses.
- Standalone command exclusivity, including version, check-in, and update modes.
- Configuration-backup timestamp failure handling and dependency checks.
- Atomic updates work with older BusyBox utilities, including version 1.30.

### Documentation

- Public examples use runtime-discovered identities and generic caller names.
- Usage and release history live in Markdown; private audit data stays outside
  the repository. Added the pilot, scheduling, and rollback guide.

Historical version spellings below are preserved from the original release
lineages.

## Debian releases

### 1.04

- Restored the intended interactive no-argument first-run behavior.
- When run interactively with no arguments and no config, the helper now
  reuses the normal missing-config prompt flow and can launch setup immediately.
- Preserved interactive no-argument help guidance when config already exists.
- Preserved non-interactive missing-config failure behavior with clear guidance.
- Updated header notes and usage text to reflect the corrected entry behavior.

### 1.03.0

- Added friendly no-argument interactive guidance before normal argument parsing.
- When run interactively with no arguments and no config, the helper now
  instructs the user to invoke --setup.
- When run interactively with no arguments and config is present, the helper
  now instructs the user to invoke --help.
- Updated usage text and documentation to match the new entry behavior.

### 1.02.0

- Standardized on a per-host global config under /usr/local/etc/host-pushover.
- Removed the earlier per-user/XDG configuration direction.
- Added optional per-application overrides under /usr/local/etc/host-pushover/apps/.
- Wrote the global config with host-wide readable permissions so non-root
  service accounts can use the helper.

### 1.01.0

- Added interactive setup and configuration-writing workflow.
- Added visible-input questionnaire with per-answer confirmation.
- Added final review/edit screen before writing the config file.
- Added manual --test mode and setup-time optional test delivery.
- Added interactive first-run prompting when config is missing during a
  normal command invocation.

### 1.00.0

- Initial host-generic release.
- Refactored the prior single-host helper into a reusable host-aware helper.
- Added automatic host label resolution for notification titles.
- Made per-application config optional, with sensible built-in defaults.
- Preserved quiet-on-success behavior for normal message delivery.

## Legacy DSM releases

These describe the retired DSM lineage, whose features are incorporated in the
unified release above. The migration tool recognizes `2.03-dsm` explicitly as a
legacy version eligible for migration to unified `2.0.0`.

### 2.03-dsm

- Added --version for deterministic local version reporting without HOME,
  configuration, DNS, or network access.
- Added --check-in as a first-class end-to-end health/sanity check.
- --check-in validates dependencies and the effective secure Pushover
  configuration without printing secrets.
- --check-in sends a forced OK notification containing the running script
  version, dynamic host label, timestamp, and configuration-validation result.
- --check-in exercises the normal v2.02-dsm retry/self-healing transport path,
  so successful receipt also proves DNS/network/TLS/API delivery.
- Preserved --test behavior for backward compatibility.
- Updated header usage documentation and full version history.

### 2.02-dsm

- Added bounded self-healing retries for transient Pushover transport failures,
  including DNS resolution failures, connection failures, timeouts, selected
  TLS/socket failures, and transient HTTP status codes.
- Added exponential retry backoff with defaults of 6 total attempts,
  5-second initial delay, and 30-second maximum delay.
- Added optional PUSHOVER_RETRY_ATTEMPTS, PUSHOVER_RETRY_INITIAL_DELAY,
  and PUSHOVER_RETRY_MAX_DELAY configuration overrides; existing configs
  remain valid without modification.
- Avoids retrying permanent 4xx API/configuration failures such as invalid
  credentials or malformed requests, except explicitly transient 408/425/429.
- Emits retry diagnostics to stderr while preserving quiet successful delivery.
- Added sleep to dependency validation.
- Updated DSM header usage examples and documentation.

### 2.01-dsm

- Added scheduler-safe home-directory discovery for Synology DSM.
- When HOME is absent or invalid, resolves the executing user's home by
  matching the current UID against /etc/passwd.
- Removed the startup dependency on an interactive/login-shell HOME value.
- Initializes config paths only after the effective user home is resolved.
- Exports the resolved HOME for child processes when DSM Task Scheduler
  did not supply one.
- Preserved fail-closed behavior if no valid writable home can be resolved.
- Preserved the existing CLI/caller contract and secure DSM config layout.

### 2.00-dsm

- Added a Synology DSM 7.x-specific deployment profile.
- Moved installation to the invoking user's $HOME/bin directory.
- Moved global and per-caller configuration beneath
  $HOME/.config/host-pushover.
- Changed configuration directories to mode 0700 and the credential-bearing
  global config file to mode 0600.
- Removed the DSM setup requirement for root privileges.
- Added DSM HOME validation before configuration paths are used.
- Expanded dependency validation to cover all unguarded external commands
  used by setup, configuration, and delivery paths.
- Preserved the existing CLI/caller contract for compatibility with callers.
- Preserved dynamic hostname discovery and fail-closed non-interactive behavior.
