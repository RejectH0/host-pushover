#!/usr/bin/env bash
# RejectH0 private use only. DO NOT DEPLOY. Read this directory's README.md.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'The migration runner requires Bash 4.4 or newer.\n' >&2
    exit 1
fi
set -euo pipefail
umask 077

usage() {
    cat <<'HELP'
REJECTH0 PRIVATE USE ONLY — DO NOT DEPLOY

Usage: bash run-upgrade.sh --acknowledge-private-use \
         --archive <reviewed-bundle.tar.gz> --sha256 <trusted-archive-sha256> [options]

  --target <path>       Existing script; otherwise discover it in PATH
  --dry-run             Verify only; do not install, schedule, or send a check-in
  --no-check-in         Skip the post-upgrade Pushover health notification
  --no-schedule         Skip daily update-check scheduling setup
  --state-dir <path>    Override the persistent root-owned updater state directory
  --help                Show this message

Run as the usual notification account, using sudo for the bootstrap when needed.
Read README.md before opting in. This opt-in is not an authentication mechanism.
HELP
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

acknowledged=0 archive="" expected="" target="" dry_run=0 check_in=1 work=""
declare -a update_options=() root_command=() members=()
while (( $# )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --acknowledge-private-use) acknowledged=1; shift ;;
        --archive|--sha256|--target|--state-dir)
            if (( $# < 2 )) || [[ -z "$2" ]]; then fail "Missing value for $1"; fi
            case "$1" in
                --archive) archive="$2" ;;
                --sha256) expected="${2,,}" ;;
                --target) target="$2" ;;
                --state-dir) update_options+=(--state-dir "$2") ;;
            esac
            shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --no-check-in) check_in=0; shift ;;
        --no-schedule) update_options+=(--no-schedule); shift ;;
        *) fail "Unknown option: $1" ;;
    esac
done

printf 'REJECTH0 PRIVATE USE ONLY — DO NOT DEPLOY\n' >&2
(( acknowledged )) || fail 'Refusing to run without --acknowledge-private-use. Read README.md.'
[[ -n "${archive}" && -f "${archive}" ]] || fail '--archive must identify an existing reviewed bundle.'
[[ "${expected}" =~ ^[a-f0-9]{64}$ ]] || fail '--sha256 requires the trusted archive SHA-256 from the reviewed build.'
for tool in cp mktemp mkdir tar sha256sum stat rm; do
    command -v "${tool}" >/dev/null 2>&1 || fail "Missing command: ${tool}"
done
if [[ -z "${target}" ]]; then target="$(type -P host-pushover.sh || true)"; fi
[[ -n "${target}" && -f "${target}" ]] || fail 'Installed script not found; provide --target with its existing path.'

work="$(mktemp -d "${TMPDIR:-/tmp}/host-pushover-migration.XXXXXXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
cp -- "${archive}" "${work}/archive.tar.gz"
actual="$(sha256sum "${work}/archive.tar.gz")"
[[ "${actual%% *}" == "${expected}" ]] || fail 'Archive checksum mismatch; nothing was installed.'
printf 'Archive SHA-256 verified.\n'

# Only the four expected top-level files may enter the temporary bundle.
tar -tzf "${work}/archive.tar.gz" > "${work}/members"
mapfile -t members < "${work}/members"
(( ${#members[@]} == 4 )) || fail 'Unexpected archive contents.'
declare -A seen=()
for member in "${members[@]}"; do
    case "${member}" in
        host-pushover.sh|upgrade-host-pushover.sh|update-manifest.txt|SHA256SUMS) ;;
        *) fail 'Unexpected archive member.' ;;
    esac
    [[ -z "${seen[${member}]:-}" ]] || fail 'Duplicate archive member.'
    seen["${member}"]=1
done
mkdir "${work}/bundle"
tar -xzf "${work}/archive.tar.gz" -C "${work}/bundle"
for member in "${members[@]}"; do
    file="${work}/bundle/${member}"
    [[ -f "${file}" && ! -L "${file}" && "$(stat -c %h "${file}")" == 1 ]] || fail 'Bundle files must be regular files without links.'
done
bootstrap="${work}/bundle/upgrade-host-pushover.sh"
"${BASH}" -n "${bootstrap}"
if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || fail 'The bootstrap requires root; sudo is unavailable.'
    root_command=(sudo)
fi

"${root_command[@]}" "${BASH}" "${bootstrap}" \
    --target "${target}" --release-dir "${work}/bundle" "${update_options[@]}" --dry-run
if (( dry_run )); then exit 0; fi

"${root_command[@]}" "${BASH}" "${bootstrap}" \
    --target "${target}" --release-dir "${work}/bundle" "${update_options[@]}"
"${BASH}" "${target}" --version
if (( check_in )); then
    if ! "${BASH}" "${target}" --check-in; then
        fail 'Upgrade completed, but the health check failed. The installed upgrade remains in place.'
    fi
    printf 'Post-upgrade Pushover health check accepted.\n'
fi
