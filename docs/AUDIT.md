# Migration and v2.0 design audit

Audit date: 2026-09-07. This records the migrated baseline and a proposed design;
v2.0 has not been implemented or released.

## Public repository baseline

The Debian `1.04` source was copied into a user-owned development workspace
and verified against the original with SHA-256. The original working tree was
clean. A fresh `main` repository was created without importing legacy Git
history, remotes, or SSH settings. The original directory remains available
locally for recovery.

Documentation and usage examples were then generalized for public publication,
and the long source header/footer was moved into Markdown documentation.
Deployment-specific paths, hostnames, account details, and migration fingerprints
are kept in a private local audit record outside the repository.

The public repository is
[RejectH0/host-pushover](https://github.com/RejectH0/host-pushover).
The separate DSM source was inspected without modification. No production
script, configuration file, or scheduled job was changed by this audit.

## One codebase is appropriate

The Debian script defines 68 functions. DSM retains all of them, with 59
byte-identical function bodies, nine changed bodies, and seven additional
functions. Most notification, configuration, and setup logic is already shared.

Maintain one Bash script with a small platform profile for path selection,
permissions, home-directory resolution, and existing transport defaults.
Keep both deployment profiles within the same release and test them together.
A package system or two separately maintained runtime scripts is unnecessary
for the differences observed here.

| Behavior | Debian baseline | DSM baseline |
| --- | --- | --- |
| Script version | `1.04` | `2.03-dsm` |
| Intended installation | `/usr/local/bin/host-pushover.sh` | User's `~/bin/host-pushover.sh` |
| Configuration root | `/usr/local/etc/host-pushover` | Executing user's `~/.config/host-pushover` |
| Configuration files | `config` and optional `apps/<caller>.conf` | Same names and override model |
| Configuration directory/file modes | `0755` / `0644` | `0700` / `0600` |
| Home resolution | Not needed for configuration | `HOME`, with UID lookup in `/etc/passwd` as fallback |
| Transport attempts by default | One | Six, with bounded backoff |
| Version and health commands | Absent | `--version`, `--check-in` |

Existing configuration paths, contents, permissions, precedence, and setup flow
are compatibility requirements. The updater must not run setup, rewrite
configuration, or relocate credentials. DSM's optional retry settings must
remain accepted. Avoid silently changing Debian's retry defaults during this
migration: DSM's current defaults can spend approximately 275 seconds across
six 30-second request timeouts and five backoff delays.

The DSM source targets DSM 7.x. Actual NAS versions, available Bash/curl tools,
installed paths, and Task Scheduler accounts remain to be confirmed on the NASes.

## Version and update design

Use `2.0.0` for the unified release, displayed as v2.0 where convenient, and
three-component numeric versions thereafter. The existing Debian constant is
literally `1.04`; preserve that spelling in historical records. Treat legacy
DSM `2.03-dsm` as a separate release lineage. The bootstrap must explicitly
recognize it as eligible to migrate to unified `2.0.0`; ordinary numeric or
lexicographic comparison would give the wrong answer. Subsequent unified
versions should compare numeric components, without floating-point arithmetic,
leading-zero ambiguity, or a dependency on GNU `sort -V`.

Recommended publication and checking flow:

1. Publish a stable GitHub release containing the script, bootstrap installer,
   checksums, and a small manifest with a format identifier, version, fixed
   artifact name, and SHA-256. A manifest can be a few hundred bytes; actual
   traffic also includes TLS, headers, and redirects.
2. Discover the manifest using GitHub's documented
   `/releases/latest/download/<asset>` URL. Download the actual script from the
   specific validated version's release so a newly published release cannot
   mix a manifest with a different script. Enable immutable releases when the
   repository is ready. GitHub documents both
   [latest release asset links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
   and [immutable assets and tags](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).
3. Check at most once per day by default, with staggered scheduling, bounded
   timeouts, and failure backoff. Cache the manifest and any supported validator;
   verify conditional GET behavior against the actual release endpoint.
   Notification delivery must not wait for GitHub or inherit an update-check
   failure as its own exit status. Keep checks outside the delivery path.
4. Persist update availability separately from Pushover configuration. Include
   installed version, latest known version, last attempt, and last successful
   check; distinguish stale/unknown status from confirmed current status.
   Existing non-root callers may read appropriate status, but root must not
   trust user-writable cached update metadata when installing.
5. Provide an explicit check/status command and an offline `--version` command.
   Keep successful automated message delivery quiet. The normal status display
   can identify the newer version and show the root `--update` instruction.
6. Only an explicit root `--update` invocation installs code. Re-fetch and
   validate trusted metadata, enforce size and time limits, verify HTTPS and
   SHA-256, check Bash syntax and the embedded version, preserve a backup, set
   ownership/mode, and atomically replace the selected installed script using
   staging on the same filesystem. Serialize updates and provide rollback.
   Failed downloads or validation must leave the installed file intact.

The initial trust model is the selected GitHub repository over verified HTTPS.
A checksum obtained from the same release detects mismatched/corrupt downloads;
it is not independent publisher authentication. An embedded signing key and
signed manifest can add that guarantee if the deployment tools support it.
GitHub's attestation-verification CLI should not become a required NAS runtime
dependency merely for this small helper.

For a public repository, public release downloads avoid deploying GitHub
credentials to every host. A private repository needs a separate download
authentication design; GitHub credentials must not enter Pushover configuration.
Avoid assuming modern curl options exist on DSM: curl added its dedicated
ETag save/compare options in
[7.68.0](https://curl.se/ch/7.68.0.html). Portable header handling is an alternative.

## Bootstrap and staged rollout

Provide one root-run upgrade script for recognized Debian and DSM baselines.
It should support inspection/dry-run, an explicit target path, a pinned version,
backup, rollback, and safe repeated invocation. It should identify legacy
versions from file contents without executing the legacy script as root.

On DSM, derive the installation identity from the explicit target and its
owner. Do not select root's home simply because the updater runs under `sudo`,
and do not source a user's notification configuration as part of a root update.
Keep existing script filenames/paths and scheduled command lines working.
Require an explicit target if discovery is ambiguous, and report local script
modifications before replacing them. Backups containing credentials must stay
outside Git.

Validate locally with mocked network responses, then pilot one Debian host and
each DSM NAS before rolling out to the remaining devices. Record the previous
and resulting versions, target path, checksum, and backup location. Verify
configuration files remain byte-identical with the same ownership and modes.
An end-to-end Pushover check-in can be run explicitly during the approved pilot.

## Audit findings and validation

- Both scripts pass `bash -n` on this Debian host.
- ShellCheck finds two warnings in Debian: unused `SCRIPT_VERSION` (SC2034),
  and a declaration masking command-substitution status in the
  configuration backup function (SC2155). DSM has the equivalent SC2155 warning.
- A pure-function check confirms both response parsers accept `{"status":10}`
  as success because they search for the substring `"status":1`. This is a
  defensive-parsing defect; there is no evidence of a live delivery incident.
- Pure argument-parser checks confirm DSM accepts `--version --check-in`,
  `--version --setup`, and `--check-in --test`. Its exclusive-mode count omits
  the added commands. Include all standalone commands in v2.0 validation.
- Debian's `--help` succeeds. DSM's `--version` succeeds with `HOME` absent.
- Neither baseline implements update discovery, self-update, release metadata,
  a bootstrap migration, or automated release tests.

The parser checks loaded function definitions in isolated subprocesses without
calling `main`. No audit command sent Pushover notifications, validated live
credentials against an API, or changed a deployed script. NAS execution and
end-to-end update behavior have not yet been tested.

## Information still needed

- DSM version, actual installed script path, and execution account on each NAS.
- Whether update availability should also send a Pushover notice once per new
  release; the conservative default is stored status and interactive guidance.
