# Design and implementation audit

The initial baseline audit favored consolidation: the system script defined
68 functions, and 59 of them were byte-identical in the DSM variant. The main
differences were paths and permissions, scheduler home resolution, retries, and
version/health commands. Those differences are now handled in one script.

## Configuration compatibility

| Behavior | System profile | DSM profile |
| --- | --- | --- |
| Configuration root | `/usr/local/etc/host-pushover` | Executing account's `~/.config/host-pushover` |
| Configuration names | `config`, `apps/<caller>.conf` | Same |
| Directory / config modes | `0755` / `0644` | `0700` / `0600` |
| Default transport attempts | One | Six with bounded backoff |
| Setup identity | Root | Notification account |

The configuration schema, precedence, questionnaire, and notification commands
are retained. Upgrades replace script code, preserving ownership and mode. They
do not source, relocate, regenerate, or chmod notification configuration.

DSM detection uses operating-system markers, without an account name, model,
firmware build, volume number, or architecture match. Missing or unsuitable HOME
is resolved through the executing UID's account record. The update path is
separate from notification environment/configuration initialization.

## Update design

- A stable release carries the script, generated bootstrap, a small manifest,
  and checksums. The bootstrap is extracted from the runtime's updater block;
  there is one maintained implementation of update validation and installation.
- Discovery uses GitHub's documented latest-release asset URL. Checks are
  scheduled separately and cache their result, including an ETag where supplied.
- Installation re-fetches metadata and downloads the version-specific artifact
  over verified HTTPS. It rejects unsupported manifests/versions, checksum or
  embedded-version mismatches, invalid Bash syntax, and unintended downgrades.
- A root-owned state tree stores public cached status plus private backups,
  receipts, locks, and the verified scheduled checker. Root never executes an
  automatically changing per-user notification script for periodic checks.
- A failed download or validation preserves the installed script. Successful
  replacement uses staging on the target filesystem and atomic `mv -T`.
  Catchable interruptions clean temporary files and locks. Uncatchable shutdown
  may leave a lock requiring operator review.
- Managed-file edits are detected using the installed checksum. Legacy files
  have no authoritative managed checksum; their original bytes are backed up
  before replacement. Rollback verifies the stored backup and its metadata.
- Legacy `2.03-dsm` is recognized as a separate lineage eligible for migration
  to unified releases beginning at `2.0.0`, not compared as version `2.3`.

The selected GitHub repository over HTTPS is the trust boundary. A checksum from
that same release is an integrity check, not independent publisher authentication.
Immutable release assets are recommended; independent signatures remain future
work. Neither Git nor GitHub credentials are required on deployed hosts.

## Automated evidence

The test suite uses synthetic configuration and a closed curl stub. Root tests
use temporary installation and state directories, not deployed scripts. Coverage
includes both configuration profiles, missing HOME, offline version reporting,
CLI conflicts, JSON response parsing, caller overrides, retry behavior, legacy
migration, dry-run, pinned versions, malformed downloads, 304/cache behavior,
failure backoff, flag clearing, local edits, ownership preservation, backup
validation, concurrency, interruption, and rollback. Update/rollback cases also
run with BusyBox utilities. Cron writing is tested in a temporary directory.

Bash syntax and ShellCheck are required for both the runtime and generated
bootstrap. CI runs on Debian Bookworm/Trixie and Ubuntu 22.04/24.04. Hardware,
firmware-specific tools, scheduler contexts, and live Pushover delivery still
need the real-device pilot described in [ROLLOUT.md](ROLLOUT.md).

## Privacy and migration records

The public repository contains generic examples and runtime discovery. Detailed
machine-specific migration records and original source recovery copies stay
outside Git. Original Git history and root-specific SSH settings were not
imported. Public commit attribution uses a GitHub handle and noreply address.

No production configuration or existing notification schedule was changed by
the development tests. Publishing a stable release and deploying it across the
fleet remain explicit rollout steps after pilot validation.
