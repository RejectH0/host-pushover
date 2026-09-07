# Changelog

## Unreleased

- Prepare the public repository from the existing `1.04` baseline.
- Move script usage documentation and release history into Markdown files.
- Use generic examples and keep private deployment records outside the repository.
- Record the proposed unified v2.0 update and migration work in `TODO.md`.

The current script remains `1.04`. Unified `2.0.0` is planned and has not been
released. Historical version spellings below are preserved from the source.

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

These describe the separately developed DSM lineage. Its features are being
evaluated for the unified release; the current Debian script does not yet
include them. `2.03-dsm` must be recognized explicitly by the migration tool,
rather than compared as an ordinary unified release version.

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
