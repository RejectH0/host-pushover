# host-pushover

A shared Pushover notification helper for Debian, Raspberry Pi OS, Ubuntu, and
Synology DSM. **One `host-pushover.sh` serves every platform.** The legacy DSM
variant has been absorbed into the unified script.

The current development version is **2.0.0**. Release assets can be built and
piloted locally; a stable GitHub release should be published after the hardware
pilot in [docs/ROLLOUT.md](docs/ROLLOUT.md).

## Requirements and platform detection

Use Bash 4.4 or newer, curl with working HTTPS certificate validation, and the
usual Linux command-line tools. Notification delivery uses `awk`, `sed`, `tr`,
`grep`, `hostname`, `date`, `mktemp`, `cp`, `mkdir`, `chmod`, `rm`, `cat`, and `sleep`.
Updates additionally require `sha256sum`, `stat -c`, `chown`, `rmdir`, and `mv -T`.
The Linux `/proc/self/fd` interface pins staging directories during replacement.
GNU and BusyBox update utilities are exercised by the automated tests. Git,
GitHub CLI, jq, and Python are **not required on deployed devices**.

The script detects DSM from standard Synology system files. It does not match a
specific NAS model, firmware build, username, hostname, home-volume number, or
CPU architecture. Other Linux systems use the system profile. `--profile system`
or `--profile dsm` provides an explicit override when needed.

| Profile | Normal installation | Configuration root | Directory / config modes |
| --- | --- | --- | --- |
| System | `/usr/local/bin/host-pushover.sh` | `/usr/local/etc/host-pushover` | `0755` / `0644` |
| DSM | Executing user's `~/bin/host-pushover.sh` | Executing user's `~/.config/host-pushover` | `0700` / `0600` |

For DSM, an existing `HOME` must belong to the executing account. Otherwise the
script resolves that account by UID using the account database, with a local
passwd-file fallback. It never substitutes a built-in account name. The updater
uses the explicit installed target and its ownership, independently of `HOME`.

Inspect the actual runtime environment without loading configuration or making
network requests:

```bash
bash host-pushover.sh --version
bash host-pushover.sh --paths
```

`--version` also works when `HOME` is absent. `--paths` reports the profile,
execution UID, and resolved configuration paths. Run it in the scheduler's
execution context when diagnosing a DSM task.

## Installation and existing installations

For a **new system installation**:

```bash
sudo install -m 0755 host-pushover.sh /usr/local/bin/host-pushover.sh
sudo /usr/local/bin/host-pushover.sh --setup
```

For a **new DSM installation**, run these as the intended notification account:

```bash
mkdir -p "$HOME/bin"
install -m 0750 host-pushover.sh "$HOME/bin/host-pushover.sh"
/bin/bash "$HOME/bin/host-pushover.sh" --setup
```

For an **existing installation**, use the bootstrap procedure in
[docs/ROLLOUT.md](docs/ROLLOUT.md). It migrates both legacy release lineages,
including `1.04` and `2.03-dsm`. Keep the existing invocation path. Do not rerun
setup to upgrade: the configuration files and their permissions stay intact.

## Configuration

Each profile uses `config` and optional `apps/<caller>.conf` beneath its existing
configuration root. These are Bash variable-assignment files. Precedence remains:

1. Built-in defaults.
2. Global configuration.
3. Optional caller-specific configuration.
4. Applicable command-line options, such as an explicit title or forced delivery.

The interactive `--setup` questionnaire, confirmation/review flow, timestamped
configuration backup, and optional test message are retained. It asks for the
application token, recipient key, device, sound, connection timeout, request
limit, and host label. A blank host label enables runtime hostname discovery.
Run system setup as root and DSM setup as the notification account.

Example global settings (placeholders only):

```bash
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
PUSHOVER_HOST_LABEL=''
```

Caller-specific files retain the existing variables:

```bash
# apps/backup-job.conf
APP_PUSHOVER_ENABLED=true
APP_PUSHOVER_DEBUG=false
APP_PUSHOVER_TITLE_PREFIX='Backups'
APP_PUSHOVER_FAILURE_PRIORITY=1
APP_PUSHOVER_DEBUG_PRIORITY=0
APP_PUSHOVER_SOUND=''
APP_PUSHOVER_DEVICE=''
```

The caller name accepts letters, digits, dots, underscores, and hyphens. Missing
caller configuration uses the defaults. `PUSHOVER_HOST_LABEL` overrides hostname
discovery when deliberately set; otherwise the script tries `hostname -s`, then
`hostname`, then `unknown-host`.

DSM retains six total transport attempts with exponential delays of 5, 10, 20,
30, and 30 seconds. System hosts retain one attempt by default. The existing
optional `PUSHOVER_RETRY_ATTEMPTS`, `PUSHOVER_RETRY_INITIAL_DELAY`, and
`PUSHOVER_RETRY_MAX_DELAY` settings are accepted on either profile. Retries cover
transient DNS/connection failures and selected HTTP errors; permanent API errors
are not retried. A timeout after an accepted POST can result in a duplicate
notification on retry. Retry settings do not govern GitHub update checks.

No updater settings, tokens, or state are written to Pushover configuration.

## Sending notifications

```bash
host-pushover.sh --caller backup-job --level err --message 'Backup failed'
host-pushover.sh --caller backup-job --force-send --level info --message 'Backup completed'
host-pushover.sh --caller backup-job --validate
host-pushover.sh --test
host-pushover.sh --check-in
```

Normal successful delivery is quiet. Error-level notifications are sent by
default; other levels follow the existing debug-mirroring policy unless forced.
Global/per-caller enable flags remain effective for normal sends. Validation,
setup, and explicit test/health commands provide their own feedback.

`--check-in` validates the global configuration and explicitly sends a forced
health notice containing the version, detected host label, timestamp, and
validation result. `--test` retains its original behavior. Both commands send
real notifications; automated tests use a closed network stub instead.

Use `--title` for an explicit title. Without it, titles include the detected
host, caller, optional caller prefix, and level. The script preserves the
existing configuration precedence and message-routing behavior.

Interactive invocation without arguments offers setup if configuration is
missing, or prints guidance and cached update status if it exists. A
non-interactive invocation never starts the questionnaire. Conflicting standalone
commands are rejected. Failures return nonzero; successful sends and deliberate
policy-based skips return zero.

## Update checks and installation

Update discovery and installation are separate commands:

```bash
sudo host-pushover.sh --check-update
host-pushover.sh --update-status
sudo host-pushover.sh --check-update --refresh
sudo host-pushover.sh --update --dry-run
sudo host-pushover.sh --update
```

Checks fetch a **184-byte manifest** from the public repository's latest stable
release. HTTP headers, redirects, and TLS add to the transferred bytes. Cached
ETags support `304 Not Modified`. The default successful-check interval is
24 hours; failed attempts use bounded backoff. `--refresh` deliberately bypasses
the interval. Message delivery never queries GitHub or waits for an update check.

A root-owned state directory records the manifest, check times, retry state, and
an `update-available` flag containing the newer version. The flag is separate
from Pushover configuration. `--update-status` compares the installed version
with the cached version and reports whether the cache is fresh, stale, or
unknown. A failed check preserves the last known version and marks it stale.

Root must explicitly invoke `--update` to install. It obtains fresh metadata,
downloads the version-specific release asset, validates its checksum, Bash
syntax, and embedded version, backs up the installed script, and atomically
replaces it while preserving ownership and mode. Installation never sources
notification configuration. Release downloads require no GitHub credentials.

For a DSM user installation, expand the existing target path before `sudo`:

```bash
sudo /bin/bash "$HOME/bin/host-pushover.sh" --update
```

Updater state defaults to `/var/lib/host-pushover/<target-path-hash>`. Use
`--state-dir` consistently if a different root-owned persistent location is
needed. Its directory ancestry must be trusted; user-writable directories and
symlinks are refused. The private subdirectory contains backups and a verified,
root-owned copy used by scheduled checks. Root never runs a mutable per-user
script automatically for its daily checks.

The bootstrap installs a daily cron job when a compatible cron installation is
available. On DSM it prints the command for a separate daily task running as
root in Task Scheduler. The existing boot-notification task is unchanged. On
systems without a detected cron installation, it prints an equivalent scheduling
command. Repeat scheduling setup with:

```bash
sudo host-pushover.sh --install-check-schedule
```

A lock serializes operations on each target. Normal signal interruption cleans
up temporary files and the lock. After an uncatchable termination or power loss,
a stale lock can remain: use the reported lock path, confirm its recorded PID is
not running, and remove that lock directory as root before retrying. Do not
remove a live process's lock.

Local edits to a managed script are detected using its recorded checksum.
`--allow-modified` explicitly permits replacement after review. A legacy or
unmanaged installation has no authoritative stored baseline checksum; its
original bytes are retained in the backup. Final script symlinks and multiple
hard links are refused, while directory aliases are resolved consistently.
Downgrades are refused; use the recorded rollback procedure instead.

HTTPS and the selected public repository are the release trust boundary. A
checksum from the same release detects corruption or mixed assets; it does not
provide independent publisher authentication. Keep release publication access
restricted and use immutable GitHub releases. No downloaded manifest is ever
executed as shell code.

## Development, privacy, and releases

```bash
bash scripts/check.sh
sudo python3 -m unittest discover -s tests -v
```

The first command builds `dist/`, checks Bash syntax and ShellCheck, and runs the
unprivileged tests. The second runs isolated root installation tests using only
temporary targets and synthetic network/configuration data. The CI matrix covers
Debian Bookworm/Trixie and Ubuntu 22.04/24.04, with additional BusyBox utility
checks. Actual NAS and Raspberry Pi hardware pilots remain separate.

`python3 scripts/build-release.py` produces the runtime script, a standalone
bootstrap generated from the same updater functions, `update-manifest.txt`, and
`SHA256SUMS`. The **Prepare release draft** GitHub Actions workflow runs the test
matrix and attaches these assets to an unpublished draft. Publish the stable
release only after the pilot. GitHub documents the
[latest-release asset endpoint](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
and [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).

Do not commit real hostnames, usernames, private paths, addresses, credentials,
SSH keys, or deployment inventories. Use synthetic examples and keep local
records outside the repository. Public service endpoints, the release repository,
and standard platform paths are intentional constants; deployment identities
are resolved at runtime. See [AGENTS.md](AGENTS.md).

- [CHANGELOG.md](CHANGELOG.md): completed changes and historical versions.
- [TODO.md](TODO.md): remaining validation and future work.
- [docs/AUDIT.md](docs/AUDIT.md): design findings and implementation scope.
- [docs/ROLLOUT.md](docs/ROLLOUT.md): migration, scheduling, and rollback.
