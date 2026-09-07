# 🚨 STOP — REJECTH0'S PRIVATE USE ONLY 🚨

# ⛔ DO NOT DEPLOY THIS DIRECTORY ⛔

> **THESE ARE PERSONAL MIGRATION TOOLS FOR RejectH0 ONLY.**
>
> **DO NOT USE THEM AS A GENERAL INSTALLER. DO NOT SHIP THEM IN PACKAGES,
> CONTAINERS, OR DEPLOYMENT IMAGES. DO NOT INSTALL THEM AS SERVICES, SCHEDULED
> TASKS, OR PERMANENT RUNTIME SCRIPTS.**
>
> **PUBLIC VISIBILITY DOES NOT MEAN THESE TOOLS ARE INTENDED FOR PUBLIC USE.**

This directory is visible in a **public GitHub repository**. “Private use”
describes the intended audience; it does **not** restrict access or keep its
contents confidential. It contains no private deployment data. The wrapper's
opt-in flag acknowledges this warning; it does not authenticate anyone.

The only intended use is an explicit, supervised migration by RejectH0 of an
existing installation. The installed product remains `host-pushover.sh`.
Readers looking for the supported project should start at the
[project README](../../README.md).

## Contents

| File | Purpose |
| --- | --- |
| `upgrade-host-pushover.sh` | Generated copy of the shared migration engine, retained here for review. Do not edit it directly. |
| `run-upgrade.sh` | Execution wrapper for a reviewed local archive. Requires `--acknowledge-private-use`. |

The wrapper checks the archive against a **separately trusted SHA-256**, accepts
only the four expected bundle files, runs the verified bundle's bootstrap in
dry-run mode, performs the upgrade, prints the installed version, and sends one
Pushover health-check notification. It stops on failure. A failed notification
does not undo a successful installation.

The bootstrap preserves configuration and script ownership/mode, saves a
rollback backup, and configures daily update checks where supported. Root
installation remains explicit. See the [rollout guide](../../docs/ROLLOUT.md)
for scheduling, DSM execution accounts, and rollback.

## Maintainer preparation — RejectH0 only

From the repository root, regenerate the tracked bootstrap when its shared
source changes, build the archive, and run the checks:

```bash
python3 scripts/build-release.py --sync-maintainer --archive
bash scripts/check.sh
sudo python3 -m unittest discover -s tests -v
```

The builder prints the archive name and SHA-256. It packages only the four
release files with fixed numeric ownership, empty owner names, and fixed
timestamps. It never packages local accounts, SSH keys, inventories, or other
files from `dist/`. Review the generated Git diff before publishing changes.
CI rejects a tracked bootstrap that differs from the shared engine's output.

The **Publish migration prerelease** workflow publishes the reviewed archive,
`run-upgrade.sh`, and `migration-SHA256SUMS` as public GitHub release assets when
the maintainer pushes a tag named `migration-v<VERSION>-pilot.<NUMBER>`. The tag
version must match the runtime version, and the full CI matrix must pass first.
Each new bundle gets a new tag; existing release assets are never overwritten.
The release is explicitly a prerelease and is not marked as the latest stable
release. Stable version discovery continues to use the stable release endpoint.

Use the matching release asset links from the
[GitHub releases page](https://github.com/RejectH0/host-pushover/releases) to
download directly on each device with HTTPS. Public downloads require no SSH
access, GitHub account, or GitHub token on the device. Manual transfer remains
available for devices without HTTPS access.

Keep the archive and runner checksums from the reviewed build separately;
computing a checksum from an untrusted download does not establish its
authenticity. Verify the runner before executing it. Archives stay in ignored
`dist/` locally; published copies are release assets, not tracked repository
files. The private-use warning applies to the release assets too.

## Maintainer execution — RejectH0 only

Run in Bash as the account that normally sends notifications. The wrapper uses
sudo for the bootstrap when that account is not root. Set these local shell
variables to the transferred archive and its trusted build checksum:

```bash
read -r -p 'Reviewed archive path: ' rollout_archive
read -r -p 'Trusted archive SHA-256: ' rollout_sha256

bash ./run-upgrade.sh --acknowledge-private-use \
  --archive "$rollout_archive" --sha256 "$rollout_sha256" --dry-run

bash ./run-upgrade.sh --acknowledge-private-use \
  --archive "$rollout_archive" --sha256 "$rollout_sha256"
```

The installed target is discovered in `PATH`; use `--target` with its existing
path if necessary. `--dry-run` never installs, schedules, or sends a notification.
Use `--no-check-in` to defer the notification, `--no-schedule` when scheduling is
managed separately, and a consistent `--state-dir` if using custom updater state.
For a DSM installation operated from a root shell, defer the check-in and run it
separately as the normal notification account. Do not change account ownership or
configuration as part of this migration.

The low-level generated bootstrap does not require the wrapper's acknowledgment
flag; it has its own explicit root/target requirements. The warnings here apply
to **both** files. Retain the reviewed archive and the reported backup location
outside Git for recovery, then remove temporary tool copies from the device.

**No hostnames, usernames, domains, credentials, SSH keys, private paths, or
deployment results belong in this directory. Keep those records outside Git.**

# ⛔ REJECTH0'S PRIVATE USE ONLY — DO NOT DEPLOY ⛔
