# TODO

This is the proposed v2.0 work plan. The currently migrated script remains
`1.04`; unchecked items are not implemented. See [the audit](docs/AUDIT.md) for
evidence, compatibility details, and design decisions.

## Publication requirements

- [x] Replace deployment-specific names and paths with generic examples.
- [x] Store private audit records outside the repository.
- [x] Review prepared files and commit attribution for private information.
- [x] Add repository instructions and ignore rules to keep credentials,
  inventories, state, and SSH keys out of Git.

Repeat the publication review for every future change.

## Development migration

- [x] Audit the root-owned Debian source and the user-owned DSM variant.
- [x] Copy the Debian working files to the user-owned development directory and
  verify their SHA-256 hashes.
- [x] Initialize fresh Git metadata on `main`, excluding the old Gogs/SSH setup.
- [x] Preserve the original root-owned directory as a recovery copy.
- [x] Establish `CHANGELOG.md` and this development plan.
- [x] Configure the public GitHub remote and a dedicated user-level SSH key.
- [x] Register the SSH public key with GitHub and verify SSH authentication.
- [x] Set repository-local commit attribution to the public GitHub handle and
  GitHub noreply email address.
- [x] Prepare the reviewed public baseline for the initial GitHub commit.

## v2.0: one script for Debian and DSM

- [ ] Confirm NAS DSM/Bash/curl versions, installed paths, and scheduler accounts.
- [ ] Share delivery and setup logic with small platform-specific path,
  permission, home-resolution, and existing retry-default profiles.
- [ ] Preserve both existing configuration trees, contents, modes, override
  order, CLI callers, and setup process.
- [ ] Retain DSM retry settings and scheduler home resolution.
- [ ] Make offline `--version` and explicit `--check-in` available consistently.
- [ ] Adopt unified `2.0.0` versioning and recognize `1.04` and `2.03-dsm` as
  legacy migration inputs with distinct release lineages.
- [x] Move the long source header/footer documentation into README and
  CHANGELOG, retaining the shebang, version constant, and useful code comments.
- [ ] Update README with actual supported profiles and tested upgrade commands.

## v2.0: update discovery and installation

- [ ] Publish a small stable-release manifest and version-specific artifacts.
- [ ] Add numeric version comparison, strict manifest parsing, and release
  validation without evaluating remote content as shell code.
- [ ] Add daily, staggered, bounded checks and separate cached status. Verify
  conditional HTTP requests with the chosen GitHub endpoint and deployed curl.
- [ ] Distinguish update available, current, and unknown/stale status.
- [ ] Keep GitHub requests outside the notification delivery path.
- [ ] Provide explicit update check/status commands and interactive guidance.
- [ ] Require root and explicit `--update` for installation; revalidate trusted
  metadata independently of caches writable by notification callers.
- [ ] Download to safe temporary storage, enforce limits, verify checksum,
  version, and Bash syntax, and reject unsupported targets.
- [ ] Lock concurrent updates, back up the installed script, atomically replace
  it, preserve intended ownership/mode, and implement rollback.
- [ ] Preserve DSM installation ownership and user identity when root updates;
  avoid sourcing user configuration or using root's home for target selection.

## v2.0: bootstrap and rollout

- [ ] Provide a single legacy upgrade script with dry-run, explicit target,
  pinned-version installation, backup, rollback, and idempotent reruns.
- [ ] Recognize legacy versions without executing unknown/local scripts as root.
- [ ] Keep existing invocation paths and configuration files unchanged.
- [ ] Define how update checks are scheduled on Debian and DSM without
  introducing duplicate jobs or changing existing notification jobs.
- [ ] Cover version edge cases, failed/malformed downloads, checksum mismatch,
  concurrent updates, interrupted installation, and rollback with meaningful
  isolated tests.
- [ ] Test notification compatibility with mocked Pushover transport, both
  configuration profiles, missing HOME, and conflicting command modes.
- [ ] Pilot one Debian host and both DSM NASes, checking configuration hashes
  and permissions before and after migration.
- [ ] Prepare a concise rollout checklist and per-device result record for the
  remaining fleet; publish stable v2.0 only after pilot validation.

## Planned bug fixes

- [ ] Tighten response parsing so a status other than the exact success value
  cannot match the `"status":1` substring.
- [ ] Count every standalone CLI mode, including version, check-in, and update
  modes, when rejecting incompatible argument combinations.
- [ ] Handle backup timestamp command failure explicitly (ShellCheck SC2155).
- [ ] Consume the version constant in offline version reporting (SC2034).
- [ ] Complete dependency checks for all unguarded commands, including DSM
  home-resolution tools, while keeping offline version reporting independent.

## Later possibilities

- [ ] Optional once-per-release Pushover update notice with deduplication.
- [ ] Independent manifest signature verification if the fleet's available
  tools support a practical signing-key and rotation process.
- [ ] Fleet inventory/reporting beyond the initial bootstrap result records.
