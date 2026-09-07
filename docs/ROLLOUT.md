# Migration and rollout

Use the same `host-pushover.sh` on every device. The bootstrap recognizes the
legacy system releases and DSM `2.00-dsm` through `2.03-dsm` as migration inputs,
then switches the installation to unified `2.0.0` versioning. Existing paths,
configuration files, permissions, and notification jobs are retained.

## Prepare a pilot bundle

On the development machine:

```bash
bash scripts/check.sh
sudo python3 -m unittest discover -s tests -v
```

Copy the four files in `dist/` into a temporary directory on a pilot device using
your existing administrative transfer method. The bundle contains:

- `host-pushover.sh`
- `upgrade-host-pushover.sh`
- `update-manifest.txt`
- `SHA256SUMS`

Verify the transfer inside that directory:

```bash
sha256sum -c SHA256SUMS
```

Keep deployment inventories and before/after records outside the public repo.
The first pilot should cover one system host and each DSM NAS. Also exercise a
Raspberry Pi and each Ubuntu generation used in the deployment before completing
the fleet rollout. Tests with BusyBox utilities are not a substitute for a real
DSM Task Scheduler run.

## Identify the installed target

Use the actual path already used by existing callers. For system installations:

```bash
target="$(command -v host-pushover.sh)"
```

For a conventional DSM user installation, log in as the notification account:

```bash
target="$HOME/bin/host-pushover.sh"
```

This expands the account-specific path locally before `sudo`. No username is
built into the bootstrap or release code. If the device uses another path, set
`target` to that existing path. Directory aliases are resolved; a final script
symlink or a file with multiple hard links is refused for explicit review.

Record the installed script checksum, owner, group, and mode. Record equivalent
hashes and metadata for `config` and existing `apps/*.conf` files using local
administrative tooling. Do not print credentials or copy configuration into Git.

## Verify, then install

From the transferred bundle directory:

```bash
sudo /bin/bash ./upgrade-host-pushover.sh \
  --target "$target" --release-dir "$PWD" --dry-run

sudo /bin/bash ./upgrade-host-pushover.sh \
  --target "$target" --release-dir "$PWD"
```

The dry run verifies the candidate and reports the target, versions, owner,
mode, and checksum. It creates temporary updater bookkeeping but does not replace
the installed script, change configuration, or create scheduled jobs.

The installation preserves the original script in a root-only backup and records
its metadata. It uses a same-filesystem staging directory and atomic rename.
The target owner and permissions are retained. A root-owned verified checker is
stored separately for scheduled checks; it never sources Pushover configuration.

Existing configuration is not migrated, regenerated, or rewritten. Do not run
`--setup` as part of an upgrade.

## DSM Task Scheduler

A scheduled task executes as a Unix account even when it is configured through
a web interface. The account used for the existing notification task must remain
the account whose notification configuration should be loaded. A web login alone
does not establish a task's execution identity. `--paths` reports the execution
UID and resolved configuration directory without exposing credential values.

Keep the current boot-notification command if it already works. If a portable
wrapper is needed, this example discovers a local account home without naming a
user or storage volume:

```bash
task_home="$(awk -F: -v uid="$(id -u)" '$3 == uid { print $6; exit }' /etc/passwd)"
[ -n "$task_home" ] && [ -d "$task_home" ] || exit 1
task_host="$(hostname -s 2>/dev/null || hostname)"
task_time="$(date '+%Y/%m/%d %H%M%S')"

/bin/bash "$task_home/bin/host-pushover.sh" \
  --caller dsm-boot \
  --force-send \
  --level info \
  --title "[${task_host}] DSM System Startup" \
  --message "${task_host} boot-up sequence initiated at ${task_time}."
```

The wrapper is for local DSM accounts; sites with directory-service accounts
should resolve them with their account service. The script itself uses `getent`
when available, with a local passwd fallback.

Create a **separate daily update-check task running as root** using the exact
command printed by the bootstrap. It refers to the root-owned checker and the
discovered installed target. Do not make the root check task execute the
user-owned notification script. The check only records update availability.

To print those instructions again:

```bash
sudo /bin/bash "$target" --install-check-schedule
```

## System scheduling

When cron is detected, the bootstrap creates one daily job for the target under
`/etc/cron.d`. Its time is derived from the local hostname and target path to
stagger devices. Re-running setup replaces that job instead of duplicating it.
Verify that the cron service is enabled in the device's normal service manager.

If cron is not detected, the bootstrap prints a root command to schedule daily
using the system's scheduler. `--no-schedule` skips scheduling setup when another
management system already handles it. Keep `--state-dir` consistent if using a
custom persistent root-owned state location.

## Verify the pilot

After installation, execute these as the usual notification account:

```bash
/bin/bash "$target" --version
/bin/bash "$target" --paths
```

Check configuration hashes, ownership, and modes against the before record.
Exercise an existing caller and, when ready to send an intentional notification:

```bash
/bin/bash "$target" --check-in
```

For DSM, also run the existing boot task through Task Scheduler and verify the
expected notification. Test a sparse environment with `HOME` absent. Confirm the
daily checker is configured under root separately.

After a stable release is published, verify discovery:

```bash
sudo /bin/bash "$target" --check-update --refresh
/bin/bash "$target" --update-status
```

Before any stable release exists, GitHub returns no downloadable manifest and the
check reports unknown status with backoff. Offline pilot bundles remain usable.
A successful check records the current or available version; it never installs.
The persistent `update-available` flag contains the newer version when present.

## Rollback

Use the retained bootstrap, including when restoring a legacy script that has
no built-in rollback command:

```bash
sudo /bin/bash ./upgrade-host-pushover.sh --rollback --target "$target" --dry-run
sudo /bin/bash ./upgrade-host-pushover.sh --rollback --target "$target"
```

The most recent backup is verified against its stored checksum and metadata.
Locally modified managed scripts require explicit review and `--allow-modified`.
Configuration remains intact. Older backup files are retained for manual recovery;
the rollback command selects the latest recorded backup. A root-owned checker
can continue reporting update availability after rollback to a legacy version.

## Publish and roll out

After pilot validation, run **Prepare release draft** from GitHub Actions on
`main`. It builds the assets from that commit after the test matrix succeeds.
Review the draft, enable immutable releases, and publish it as the latest stable
release. Never replace assets under an already published version: issue a new
version instead. Do not distribute development-branch snapshots through the
update endpoint.

On remaining hosts, obtain `upgrade-host-pushover.sh` from that release through
the normal administrative distribution process. For reproducible rollout:

```bash
sudo /bin/bash ./upgrade-host-pushover.sh --target "$target" --release 2.0.0 --dry-run
sudo /bin/bash ./upgrade-host-pushover.sh --target "$target" --release 2.0.0
```

Future upgrades use the installed script:

```bash
sudo /bin/bash "$target" --update --dry-run
sudo /bin/bash "$target" --update
```

Record each device's previous/new version, target, checksum, backup location,
configuration verification, and check-in result in a private inventory. Retire
old deployment copies after the new version and rollback path have been checked.
