# host-pushover.sh

Centralized, host-aware Pushover delivery helper for Bash-oriented automation on Debian and Raspberry Pi hosts.

`host-pushover.sh` is designed to be installed once per host and reused by any local script, cron job, service account, or web application that needs consistent Pushover notification delivery. It separates host-level notification settings from application-specific behavior, preserves quiet-on-success behavior for machine use, and provides an interactive setup workflow for first-time configuration.


Current script version: `1.04`. This repository is preparing a unified Debian
and Synology DSM v2.0 release. Update discovery, self-update, and the legacy
upgrade script are planned in [TODO.md](TODO.md) and are not yet available.

## Goals

- provide a single reusable Pushover helper per host
- keep Pushover API details out of application scripts
- support both interactive human use and non-interactive automation use
- allow caller-specific overrides without duplicating global credentials
- keep normal success paths quiet for cron and script-to-script integration
- use predictable paths and operationally simple configuration

## Target environment

- Debian or Debian-like Linux
- Raspberry Pi OS
- Bash
- `curl`

## Installation

Install the helper to `/usr/local/bin`:

```bash
install -m 0755 -o root -g root host-pushover.sh /usr/local/bin/host-pushover.sh
```

The helper uses a host-wide configuration root:

```text
/usr/local/etc/host-pushover/
```

That directory contains:

```text
/usr/local/etc/host-pushover/config
/usr/local/etc/host-pushover/apps/
```

## Configuration model

### Global per-host configuration

The global configuration file applies to every caller on that host unless a caller-specific override changes selected behavior.

Path:

```text
/usr/local/etc/host-pushover/config
```

This file contains values such as:

- whether Pushover is enabled at all on the host
- the Pushover API and validation endpoints
- the Pushover application token
- the Pushover recipient user or group key
- the default device override, if any
- the default sound override, if any
- curl timeout values
- the host label used in notification titles

### Caller-specific override files

Optional caller-specific overrides live here:

```text
/usr/local/etc/host-pushover/apps/<caller>.conf
```

`<caller>` is the exact value supplied with `--caller`.

Example:

```bash
/usr/local/bin/host-pushover.sh --caller ups-monitor --level err --message "UPS switched to battery"
```

This call will cause the helper to look for:

```text
/usr/local/etc/host-pushover/apps/ups-monitor.conf
```

If the file exists, it is loaded after the global config and can override caller-specific behavior. If it does not exist, the helper simply uses the global host configuration.

## Configuration precedence

The effective configuration is built in this order:

1. built-in script defaults
2. global host config from `/usr/local/etc/host-pushover/config`
3. optional caller-specific overrides from `/usr/local/etc/host-pushover/apps/<caller>.conf`
4. runtime flags such as `--title` and `--force-send`

## Interactive first-run behavior

The helper distinguishes between interactive terminal use and non-interactive execution.

### If run interactively with no arguments

- if the global config already exists, the helper prints guidance telling the user to run `--help`
- if the global config does not yet exist, the helper enters the normal missing-config prompt flow and asks whether it should create the config now
- blank confirmation input defaults to `Yes`

### If run interactively with a real command and config is missing

The helper explains that the config is missing and asks whether it should create the config now. If the user accepts, it launches the interactive setup workflow.

### If run non-interactively and config is missing

The helper exits non-zero and prints a clear error telling the operator that the global config is missing and that the helper cannot proceed until setup is completed.

This is important for cron jobs, services, PHP-FPM pools, CGI users, and similar automation paths where the helper cannot safely prompt.

## Interactive setup workflow

Setup is available explicitly with:

```bash
/usr/local/bin/host-pushover.sh --setup
```

The current setup workflow is intended for manual terminal use and includes:

- ANSI color when an interactive terminal is detected
- a security notice before sensitive input begins
- visible input instead of hidden input, so paste and correction behavior are normal
- numbered question progress, such as `[1 of 7]`
- per-answer confirmation before moving to the next question
- a final review screen where individual answers can be edited before the file is written
- a final prompt asking whether a test message should be sent

The current questionnaire collects seven values:

1. Pushover application token
2. Pushover user or group key
3. default device name
4. default sound override
5. curl connect timeout in seconds
6. curl max time in seconds
7. host label used in notification titles

If a config file already exists, setup first loads it and uses the existing values as defaults.

If a config file already exists when setup writes a new one, the previous file is backed up with a timestamped `.bak.YYYYMMDD_HHMMSS` suffix.

## Global config file format

The global config is a Bash-style sourced config file made of variable assignments.

Representative example:

```bash
#------------------------------------------------------------------------------
# host-pushover.sh global configuration
# Generated locally by the interactive setup wizard
#------------------------------------------------------------------------------

PUSHOVER_ENABLED=true
PUSHOVER_API_URL='https://api.pushover.net/1/messages.json'
PUSHOVER_VALIDATE_URL='https://api.pushover.net/1/users/validate.json'
PUSHOVER_APP_TOKEN='__REPLACE_WITH_APP_TOKEN__'
PUSHOVER_RECIPIENT_KEY='__REPLACE_WITH_RECIPIENT_KEY__'
PUSHOVER_DEVICE=''
PUSHOVER_PRIORITY='0'
PUSHOVER_SOUND=''
PUSHOVER_CONNECT_TIMEOUT='10'
PUSHOVER_MAX_TIME='30'
PUSHOVER_HOST_LABEL=''  # Discover the hostname at runtime
```

## Caller-specific `.conf` file format

Caller-specific override files are also Bash-style sourced config files.

They are intended only for app-level behavior changes. They do not normally replace the shared application token or recipient key, because those are already defined in the host-wide global config.

Typical override variables are:

- `APP_PUSHOVER_ENABLED`
- `APP_PUSHOVER_DEBUG`
- `APP_PUSHOVER_TITLE_PREFIX`
- `APP_PUSHOVER_FAILURE_PRIORITY`
- `APP_PUSHOVER_DEBUG_PRIORITY`
- `APP_PUSHOVER_SOUND`
- `APP_PUSHOVER_DEVICE`

Example:

```bash
# /usr/local/etc/host-pushover/apps/ups-monitor.conf
APP_PUSHOVER_ENABLED="true"
APP_PUSHOVER_DEBUG="false"
APP_PUSHOVER_TITLE_PREFIX="UPS monitor"
APP_PUSHOVER_FAILURE_PRIORITY="1"
APP_PUSHOVER_DEBUG_PRIORITY="0"
APP_PUSHOVER_SOUND="siren"
APP_PUSHOVER_DEVICE="iphone"
```

## Why `apps/<caller>.conf` is useful

A caller-specific override file is useful when one application on a host should behave differently from the default behavior used by the rest of the host.

Common cases:

- one caller should use a different sound
- one caller should target a different device
- one caller should temporarily mirror non-error notifications during development or testing
- one caller should be disabled without affecting the rest of the host
- one caller should prepend a friendlier title prefix in notifications

### UPS monitor use case

Yes, UPS monitor is a good fit for a caller-specific config file.

Example call from UPS monitor:

```bash
/usr/local/bin/host-pushover.sh --caller ups-monitor --level err --message "UPS switched to battery"
```

Possible reasons to add `/usr/local/etc/host-pushover/apps/ups-monitor.conf`:

- power events should use a distinctive sound
- UPS alerts should be routed to a specific phone or tablet
- the notification title should read `UPS monitor [<detected-host>] ups-monitor [FAILURE]`
- debug notifications should be enabled temporarily while you test the web interface

If UPS monitor does not need any special behavior, it can still use `--caller ups-monitor` without having any caller-specific config file at all.

## Usage patterns

### Setup

```bash
/usr/local/bin/host-pushover.sh --setup
```

### Validate global config only

```bash
/usr/local/bin/host-pushover.sh --validate
```

### Validate with a caller-specific override

```bash
/usr/local/bin/host-pushover.sh --caller ups-monitor --validate
```

### Send a test message with the current config

```bash
/usr/local/bin/host-pushover.sh --test
```

### Send a test message for a specific caller

```bash
/usr/local/bin/host-pushover.sh --test --caller ups-monitor
```

### Send a normal error notification

```bash
/usr/local/bin/host-pushover.sh --caller ups-monitor --level err --message "UPS battery is low"
```

### Send a forced informational notification

```bash
/usr/local/bin/host-pushover.sh --caller dns-updater --force-send --level info --message "Public IP changed"
```

## Normal send policy

The helper intentionally keeps the default notification policy conservative.

- `err` is always eligible to send when notifications are enabled and the config is complete
- non-error levels send only when `APP_PUSHOVER_DEBUG=true` for that caller, or when `--force-send` is used
- if Pushover is disabled or the config is incomplete, normal sends are suppressed
- successful normal sends print nothing
- real helper failures return non-zero and write diagnostics to stderr

This makes the helper safe for cron jobs and script-to-script use.

## Title behavior

If `--title` is not supplied, the helper automatically builds a title.

Base title logic:

- if `APP_PUSHOVER_TITLE_PREFIX` is set: `<prefix> [<host-label>] <caller>`
- otherwise: `[<host-label>] <caller>`

The helper then appends a suffix based on the level, such as:

- `[FAILURE]`
- `[WARNING]`
- `[NOTICE]`
- `[OK]`
- `[INFO]`

Host label resolution order:

1. `PUSHOVER_HOST_LABEL` from config
2. `hostname -s`
3. `hostname`
4. `unknown-host`

## Dependency requirements

The helper expects these commands to be available:

- `curl`
- `sed`
- `tr`
- `mktemp`
- `grep`
- `hostname`
- `date`
- `cp`

## File permissions and operational model

The script itself is typically installed as:

```text
/usr/local/bin/host-pushover.sh
```

Recommended script mode:

```text
0755
```

The current setup workflow writes the global config with mode:

```text
0644
```

That choice allows non-root service accounts and application users to read the global config and use the helper. If you later decide to tighten permissions, you can move to a group-readable model, but that is an operational choice outside the script’s current defaults.

## Exit behavior

- `0` on successful validation, successful setup, successful test send, or successful normal send
- non-zero on actual helper failures, such as missing unreadable config, malformed config, validation failures, or Pushover API delivery failures
- a normal send that is intentionally skipped due to disabled or incomplete config remains quiet unless the helper itself must report a real failure condition

## Repository workflow model

This project is intended to fit the following operational pattern:

- maintain the Git working tree in a directory owned by your development account
- install the production helper to `/usr/local/bin/host-pushover.sh`
- keep the README up to date as the script evolves
- optionally distribute the helper to other hosts with Ansible or another deployment tool
- run setup on first installation; preserve existing configuration when upgrading

## Project documentation and privacy

- [CHANGELOG.md](CHANGELOG.md) records completed changes and legacy release history.
- [TODO.md](TODO.md) tracks proposed features, planned bug fixes, and rollout work.
- [docs/AUDIT.md](docs/AUDIT.md) explains the v2.0 design and compatibility findings.

Keep Pushover credentials, real hostnames, account-specific paths, private
addresses, SSH keys, deployment inventories, and local audit records outside
this public repository. Examples use generic caller names and discover the
hostname at runtime. Standard installation paths remain part of the supported
configuration contract.

## Recommended caller integration pattern

A calling script should normally:

1. choose a stable caller name
2. invoke the helper with that caller name every time
3. send `err` for actionable failures
4. use `--force-send` only for important informational events that should bypass the normal conservative send policy
5. add a caller-specific override file only when that application needs behavior different from the host default

Representative example:

```bash
/usr/local/bin/host-pushover.sh \
  --caller dns-updater \
  --force-send \
  --level info \
  --message "Public IP changed"
```
