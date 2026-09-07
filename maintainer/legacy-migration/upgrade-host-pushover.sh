#!/usr/bin/env bash
# Generated from host-pushover.sh by scripts/build-release.py. Do not edit.
set -u
set -o pipefail
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'The upgrade script requires Bash 4.4 or newer.\n' >&2
    exit 1
fi
# The release builder extracts this block to generate the standalone bootstrap.
# Keep it independent of Pushover settings and never source downloaded metadata.
readonly HP_REPOSITORY="RejectH0/host-pushover"
readonly HP_BOOTSTRAP=1

hp_error() { printf 'host-pushover update: %s\n' "$*" >&2; return 1; }

hp_valid_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]
}

hp_legacy_version() {
    case "$1" in
        1.00.0|1.01.0|1.02.0|1.03.0|1.04|1.4|2.00-dsm|2.01-dsm|2.02-dsm|2.03-dsm) return 0 ;;
        *) return 1 ;;
    esac
}

hp_newer() {
    # Legacy DSM belongs to a separate lineage, not unified semantic versioning.
    hp_valid_version "$1" || return 1
    if hp_legacy_version "$2"; then [[ "${1%%.*}" -ge 2 ]]; return $?; fi
    hp_valid_version "$2" || return 1
    local -a available_parts installed_parts
    local i
    IFS=. read -r -a available_parts <<< "$1"
    IFS=. read -r -a installed_parts <<< "$2"
    for i in 0 1 2; do
        (( available_parts[i] > installed_parts[i] )) && return 0
        (( available_parts[i] < installed_parts[i] )) && return 1
    done
    return 1
}

hp_read_version() {
    local file="$1" line version="" count=0 identity=0
    [[ -f "${file}" && ! -L "${file}" && "$(stat -c %s "${file}")" -le 1048576 ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == 'readonly SCRIPT_NAME="host-pushover.sh"' ]]; then identity=1; fi
        if [[ "${line}" =~ ^readonly\ SCRIPT_VERSION=\"([^\"]+)\"$ ]]; then
            version="${BASH_REMATCH[1]}"
            count=$((count + 1))
        fi
    done < "${file}"
    [[ "${identity}" == 1 && "${count}" == 1 ]] || return 1
    hp_valid_version "${version}" || hp_legacy_version "${version}" || return 1
    printf '%s\n' "${version}"
}

hp_sha256() {
    local result
    result="$(sha256sum "$1")" || return 1
    result="${result%% *}"
    [[ "${result}" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "${result}"
}

hp_target_path() {
    local path="$1" parent name
    [[ "${path}" != *$'\n'* && "${path}" != *$'\r'* ]] || return 1
    [[ "${path}" == /* ]] || path="${PWD}/${path}"
    name="${path##*/}"
    parent="${path%/*}"
    parent="$(cd -P -- "${parent:-/}" && pwd -P)" || return 1
    path="${parent%/}/${name}"
    # Resolve directory aliases (including DSM home aliases), but reject a final
    # symlink or multiply linked file instead of silently changing another target.
    [[ -f "${path}" && ! -L "${path}" && "$(stat -c %h "${path}")" == 1 ]] || return 1
    printf '%s\n' "${path}"
}

hp_trusted_directory() {
    local path="$1" check owner mode
    [[ "${path}" == /* && "${path}" != *$'\n'* && "${path}" != *$'\r'* ]] || return 1
    check="${path}"
    while :; do
        [[ -d "${check}" && ! -L "${check}" ]] || return 1
        owner="$(stat -c %u "${check}")" || return 1
        mode="$(stat -c %a "${check}")" || return 1
        [[ "${owner}" == 0 && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
        # A root-owned child beneath a sticky directory such as /tmp cannot be
        # replaced by an ordinary user. Other writable ancestors are unsafe.
        if (( (8#${mode} & 0022) != 0 && (8#${mode} & 01000) == 0 )); then return 1; fi
        [[ "${check}" == / ]] && break
        check="${check%/*}"
        [[ -n "${check}" ]] || check=/
    done
}

hp_make_state() {
    local path="${HP_STATE_ROOT}" missing=() parent
    while [[ ! -e "${path}" && ! -L "${path}" ]]; do
        missing+=("${path}")
        path="${path%/*}"
        [[ -n "${path}" ]] || path=/
    done
    hp_trusted_directory "${path}" || { hp_error 'State directory has an unsafe owner, mode, or symlink.'; return 1; }
    local i
    for ((i=${#missing[@]}-1; i>=0; i--)); do
        mkdir -m 0755 -- "${missing[i]}" || return 1
    done
    for parent in "${HP_STATE}" "${HP_PRIVATE}"; do
        if [[ ! -e "${parent}" && ! -L "${parent}" ]]; then
            mkdir -m 0755 -- "${parent}" || return 1
        fi
        hp_trusted_directory "${parent}" || { hp_error 'Unsafe update state.'; return 1; }
    done
    chmod 0700 "${HP_PRIVATE}" || return 1
    if ! mkdir -m 0700 -- "${HP_PRIVATE}/lock" 2>/dev/null; then
        hp_error "Another update/check holds the lock: ${HP_PRIVATE}/lock"
        return 1
    fi
    HP_LOCKED=1
    printf '%s\n' "${BASHPID}" > "${HP_PRIVATE}/lock/pid" || return 1
    HP_WORK="$(mktemp -d "${HP_PRIVATE}/work.XXXXXXXXXX")" || return 1
}

hp_cleanup() {
    [[ -z "${HP_STAGE:-}" ]] || rm -rf -- "${HP_STAGE}"
    [[ -z "${HP_WORK:-}" ]] || rm -rf -- "${HP_WORK}"
    if [[ "${HP_LOCKED:-0}" == 1 ]]; then
        rm -f -- "${HP_PRIVATE}/lock/pid"
        rmdir -- "${HP_PRIVATE}/lock"
    fi
    return 0
}

hp_parse_manifest() {
    local file="$1" line key value seen='|' count=0
    [[ -f "${file}" && ! -L "${file}" && "$(stat -c %s "${file}")" -le 4096 ]] || return 1
    HP_VERSION="" HP_SHA="" HP_BOOTSTRAP_SHA=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == *=* && "${line}" != *$'\r'* ]] || return 1
        key="${line%%=*}" value="${line#*=}"
        [[ "${seen}" != *"|${key}|"* ]] || return 1
        seen+="${key}|"
        count=$((count + 1))
        case "${key}" in
            format) [[ "${value}" == 1 ]] || return 1 ;;
            version) hp_valid_version "${value}" || return 1; HP_VERSION="${value}" ;;
            script_sha256) [[ "${value}" =~ ^[a-f0-9]{64}$ ]] || return 1; HP_SHA="${value}" ;;
            bootstrap_sha256) [[ "${value}" =~ ^[a-f0-9]{64}$ ]] || return 1; HP_BOOTSTRAP_SHA="${value}" ;;
            *) return 1 ;;
        esac
    done < "${file}"
    [[ "${count}" == 4 && -n "${HP_VERSION}" && "${HP_VERSION%%.*}" -ge 2 && -n "${HP_SHA}" && -n "${HP_BOOTSTRAP_SHA}" ]]
}

hp_download() {
    local url="$1" dest="$2" limit="$3" timeout="$4" etag="${5:-}" code rc
    local -a conditional=()
    if [[ "${etag}" =~ ^(W/)?\"[[:graph:]]{1,200}\"$ ]]; then
        conditional=(--header "If-None-Match: ${etag}")
    fi
    # ulimit also bounds bodies sent without Content-Length on older curl.
    code="$(
        ulimit -f "$(( (limit + 16384 + 1023) / 1024 ))" || exit 1
        curl --disable --silent --show-error --location --max-redirs 5 \
            --proto '=https' --proto-redir '=https' --connect-timeout 5 \
            --max-time "${timeout}" --max-filesize "${limit}" \
            --dump-header "${HP_WORK}/headers" --output "${dest}" \
            --write-out '%{http_code}' "${conditional[@]}" "${url}"
    )"
    rc=$?
    [[ "${rc}" == 0 && ( "${code}" == 200 || "${code}" == 304 ) ]] || {
        hp_error "Download failed (curl=${rc}, HTTP=${code:-unknown})."; return 1;
    }
    if [[ "${code}" == 200 ]]; then
        [[ -f "${dest}" && "$(stat -c %s "${dest}")" -le "${limit}" ]] || return 1
    fi
    HP_HTTP="${code}"
    HP_ETAG=""
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "${line,,}" in
            http/*) HP_ETAG="" ;;
            etag:*) HP_ETAG="${line#*:}"; HP_ETAG="${HP_ETAG# }" ;;
        esac
    done < "${HP_WORK}/headers"
    [[ "${HP_ETAG}" =~ ^(W/)?\"[[:graph:]]{1,200}\"$ ]] || HP_ETAG=""
}

hp_get_manifest() {
    local etag="${1:-}" url
    if [[ -n "${HP_RELEASE_DIR}" ]]; then
        [[ -f "${HP_RELEASE_DIR}/update-manifest.txt" && "$(stat -c %s "${HP_RELEASE_DIR}/update-manifest.txt")" -le 4096 ]] || return 1
        cp -- "${HP_RELEASE_DIR}/update-manifest.txt" "${HP_WORK}/manifest" || return 1
        HP_HTTP=200 HP_ETAG=""
    else
        if [[ -n "${HP_RELEASE}" ]]; then
            url="https://github.com/${HP_REPOSITORY}/releases/download/v${HP_RELEASE}/update-manifest.txt"
        else
            url="https://github.com/${HP_REPOSITORY}/releases/latest/download/update-manifest.txt"
        fi
        hp_download "${url}" "${HP_WORK}/manifest" 4096 20 "${etag}" || return 1
        if [[ "${HP_HTTP}" == 304 ]]; then
            if ! hp_parse_manifest "${HP_STATE}/manifest"; then
                hp_download "${url}" "${HP_WORK}/manifest" 4096 20 || return 1
                [[ "${HP_HTTP}" == 200 ]] || return 1
            else
                cp -- "${HP_STATE}/manifest" "${HP_WORK}/manifest" || return 1
                [[ -n "${HP_ETAG}" ]] || HP_ETAG="${etag}"
            fi
        fi
    fi
    hp_parse_manifest "${HP_WORK}/manifest" || { hp_error 'Invalid release manifest.'; return 1; }
    [[ -z "${HP_RELEASE}" || "${HP_VERSION}" == "${HP_RELEASE}" ]] || { hp_error 'Pinned release/version mismatch.'; return 1; }
}

hp_number_file() {
    local value=""
    if [[ -f "$1" && ! -L "$1" && "$(stat -c %s "$1")" -le 20 ]]; then
        IFS= read -r value < "$1" || true
    fi
    [[ "${value}" =~ ^[0-9]{1,12}$ ]] || value=0
    printf '%s\n' "$((10#${value}))"
}

hp_publish_file() {
    # This helper is only used inside trusted root-owned state/cron directories.
    [[ ! -d "$2" ]] || { hp_error 'A metadata destination is unexpectedly a directory.'; return 1; }
    mv -f -- "$1" "$2"
}

hp_write_public() {
    local name="$1" value="$2"
    printf '%s\n' "${value}" > "${HP_WORK}/public" || return 1
    chmod 0644 "${HP_WORK}/public" || return 1
    hp_publish_file "${HP_WORK}/public" "${HP_STATE}/${name}"
}

hp_status() {
    local installed last_success=0 next=0 failures=0 now freshness=unknown available=unknown flag=unknown
    installed="$(hp_read_version "${HP_TARGET_FILE}")" || return 1
    now="$(date +%s)" || return 1
    if hp_trusted_directory "${HP_STATE}"; then
        last_success="$(hp_number_file "${HP_STATE}/last-success")"
        failures="$(hp_number_file "${HP_STATE}/failures")"
        next="$(hp_number_file "${HP_STATE}/next-check")"
        if hp_parse_manifest "${HP_STATE}/manifest"; then
            available="${HP_VERSION}"
            freshness=stale
            if (( last_success > 0 && now >= last_success && now - last_success < 172800 && failures == 0 )); then freshness=fresh; fi
            flag=false
            hp_newer "${available}" "${installed}" && flag=true
        fi
    fi
    printf 'installed_version=%s\nlatest_known_version=%s\nupdate_available=%s\ncache=%s\nlast_success=%s\nnext_check=%s\nstate_dir=%s\n' \
        "${installed}" "${available}" "${flag}" "${freshness}" "${last_success}" "${next}" "${HP_STATE}"
    if [[ "${flag}" == true ]]; then
        printf 'Run as root: %q --update --target %q --state-dir %q\n' "${HP_TARGET}" "${HP_TARGET}" "${HP_STATE_ROOT}"
    fi
}

hp_sync_flag() (
    local installed
    installed="$(hp_read_version "${HP_TARGET_FILE}")" || return 1
    if hp_parse_manifest "${HP_STATE}/manifest" && hp_newer "${HP_VERSION}" "${installed}"; then
        hp_write_public update-available "${HP_VERSION}"
    else
        rm -f -- "${HP_STATE}/update-available"
    fi
)

hp_check() {
    local now next failures delay etag=""
    now="$(date +%s)" || return 1
    next="$(hp_number_file "${HP_STATE}/next-check")"
    if [[ "${HP_REFRESH}" == 0 ]] && (( next > now && next - now <= 86400 )); then
        hp_status
        return $?
    fi
    hp_write_public last-attempt "${now}" || return 1
    if [[ -f "${HP_STATE}/etag" && ! -L "${HP_STATE}/etag" && "$(stat -c %s "${HP_STATE}/etag")" -le 220 ]]; then
        IFS= read -r etag < "${HP_STATE}/etag" || true
    fi
    if ! hp_get_manifest "${etag}"; then
        failures="$(hp_number_file "${HP_STATE}/failures")"
        (( failures < 5 )) && failures=$((failures + 1))
        delay=$((3600 * (1 << failures)))
        (( delay <= 86400 )) || delay=86400
        hp_write_public failures "${failures}" || return 1
        hp_write_public next-check "$((now + delay))" || return 1
        hp_status
        return 1
    fi
    chmod 0644 "${HP_WORK}/manifest" || return 1
    hp_publish_file "${HP_WORK}/manifest" "${HP_STATE}/manifest" || return 1
    hp_write_public etag "${HP_ETAG}" || return 1
    hp_write_public failures 0 || return 1
    hp_write_public last-success "${now}" || return 1
    hp_write_public next-check "$((now + 86400))" || return 1
    hp_sync_flag || return 1
    hp_status
}

hp_get_candidate() {
    if [[ -n "${HP_RELEASE_DIR}" ]]; then
        [[ -f "${HP_RELEASE_DIR}/host-pushover.sh" && "$(stat -c %s "${HP_RELEASE_DIR}/host-pushover.sh")" -le 1048576 ]] || return 1
        cp -- "${HP_RELEASE_DIR}/host-pushover.sh" "${HP_WORK}/candidate" || return 1
    else
        hp_download "https://github.com/${HP_REPOSITORY}/releases/download/v${HP_VERSION}/host-pushover.sh" \
            "${HP_WORK}/candidate" 1048576 60 || return 1
        [[ "${HP_HTTP}" == 200 ]] || return 1
    fi
    [[ "$(hp_sha256 "${HP_WORK}/candidate")" == "${HP_SHA}" ]] || { hp_error 'Script checksum mismatch.'; return 1; }
    bash -n "${HP_WORK}/candidate" || { hp_error 'Downloaded script has invalid Bash syntax.'; return 1; }
    [[ "$(hp_read_version "${HP_WORK}/candidate")" == "${HP_VERSION}" ]] || { hp_error 'Downloaded script version mismatch.'; return 1; }
}

hp_install_file() {
    local file="$1" uid="$2" gid="$3" mode="$4" expected="$5"
    local stage_fd stage_identity stage_access
    # The current directory pins the target parent. Pin the root-owned staging
    # directory too, so a user renaming directories cannot redirect root writes.
    HP_STAGE="$(mktemp -d ./.host-pushover-stage.XXXXXXXXXX)" || return 1
    stage_identity="$(stat -c '%u:%a:%d:%i' "${HP_STAGE}")" || return 1
    [[ ( "${stage_identity}" == 0:700:* || "${stage_identity}" == 0:2700:* ) && ! -L "${HP_STAGE}" ]] || return 1
    exec {stage_fd}< "${HP_STAGE}" || return 1
    stage_access="/proc/self/fd/${stage_fd}"
    [[ -d "${stage_access}" && "$(stat -Lc '%u:%a:%d:%i' "${stage_access}")" == "${stage_identity}" ]] || return 1
    cp -- "${file}" "${stage_access}/${HP_TARGET##*/}" || return 1
    chown "${uid}:${gid}" "${stage_access}/${HP_TARGET##*/}" || return 1
    chmod "${mode}" "${stage_access}/${HP_TARGET##*/}" || return 1
    [[ ! -L "${HP_TARGET_FILE}" && "$(stat -c '%d:%i:%u:%g:%a:%h' "${HP_TARGET_FILE}")" == "${HP_TARGET_META}" && "$(hp_sha256 "${HP_TARGET_FILE}")" == "${expected}" && "$(stat -c '%d:%i' "${HP_TARGET%/*}")" == "${HP_PARENT_ID}" ]] || {
        hp_error 'Target changed during the operation; installation stopped.'; return 1;
    }
    # Move a source whose basename matches the target into the pinned parent.
    # Passing the directory (.) avoids treating a replaced destination symlink
    # as another directory, without requiring GNU/newer-BusyBox mv -T.
    mv -f -- "${stage_access}/${HP_TARGET##*/}" . || return 1
    exec {stage_fd}<&-
    rmdir -- "${HP_STAGE}" || return 1
    HP_STAGE=""
}

hp_finish_install() {
    printf '%s\n' "${HP_SHA}" > "${HP_WORK}/receipt" || return 1
    hp_publish_file "${HP_WORK}/receipt" "${HP_PRIVATE}/installed-sha256" || return 1
    chmod 0700 "${HP_WORK}/candidate" || return 1
    hp_publish_file "${HP_WORK}/candidate" "${HP_PRIVATE}/checker.sh" || return 1
    hp_sync_flag || return 1
    if [[ "${HP_SCHEDULE}" == 1 ]]; then
        hp_schedule || { hp_error 'Script installed, but scheduling failed; run --install-check-schedule to retry.'; return 1; }
    fi
}

hp_write_cron() {
    local cron_dir="$1" command="$2" identity minute hour cron_path staged
    hp_trusted_directory "${cron_dir}" || return 1
    identity="$(printf '%s:%s' "${HP_TARGET}" "$(hostname)" | sha256sum)" || return 1
    minute=$((16#${identity:0:4} % 60))
    hour=$((16#${identity:4:4} % 24))
    cron_path="${cron_dir}/host-pushover-${HP_ID:0:16}"
    [[ ! -L "${cron_path}" ]] || return 1
    # cron treats % specially even within shell quotes.
    command="${command//%/\\%}"
    printf 'SHELL=/bin/bash\nPATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n%d %d * * * root %s > /dev/null\n' \
        "${minute}" "${hour}" "${command}" > "${HP_WORK}/cron" || return 1
    # Stage on cron's filesystem before renaming.
    staged="$(mktemp "${cron_dir}/.host-pushover.XXXXXXXXXX")" || return 1
    if ! cp -- "${HP_WORK}/cron" "${staged}" || ! chmod 0644 "${staged}" || ! hp_publish_file "${staged}" "${cron_path}"; then
        rm -f -- "${staged}"
        return 1
    fi
    printf 'Daily update check installed: %s\n' "${cron_path}"
}

hp_schedule() {
    local command
    # Run a root-owned verified copy for checks, not a user-writable NAS script.
    [[ -f "${HP_PRIVATE}/checker.sh" && ! -L "${HP_PRIVATE}/checker.sh" ]] || return 1
    printf -v command '%q %q --check-update --target %q --state-dir %q' \
        "${BASH}" "${HP_PRIVATE}/checker.sh" "${HP_TARGET}" "${HP_STATE_ROOT}"
    if [[ -f /etc/synoinfo.conf || -f /etc.defaults/synoinfo.conf ]]; then
        printf 'Create a daily Task Scheduler task running as root with this command:\n%s\n' "${command}"
    elif [[ -d /etc/cron.d ]] && { command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; }; then
        hp_write_cron /etc/cron.d "${command}"
    else
        printf 'No supported cron installation detected. Schedule this command daily as root:\n%s\n' "${command}"
    fi
}

hp_update() {
    local installed original_hash uid gid mode recorded="" stamp backup
    installed="$(hp_read_version "${HP_TARGET_FILE}")" || { hp_error 'Unrecognized installed script/version.'; return 1; }
    original_hash="$(hp_sha256 "${HP_TARGET_FILE}")" || return 1
    IFS=: read -r uid gid mode < <(stat -c '%u:%g:%a' "${HP_TARGET_FILE}")
    [[ "${uid}" =~ ^[0-9]+$ && "${gid}" =~ ^[0-9]+$ && "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 07000) == 0 )) || { hp_error 'Refusing special permission bits on the script.'; return 1; }
    if [[ -f "${HP_PRIVATE}/installed-sha256" && ! -L "${HP_PRIVATE}/installed-sha256" ]]; then
        IFS= read -r recorded < "${HP_PRIVATE}/installed-sha256" || true
        [[ "${recorded}" =~ ^[a-f0-9]{64}$ ]] || return 1
        if [[ "${recorded}" != "${original_hash}" && "${HP_ALLOW_MODIFIED}" == 0 ]]; then
            hp_error 'Installed script was locally modified; inspect it or use --allow-modified.'; return 1
        fi
    fi
    # Installation always re-fetches metadata; it never trusts the discovery cache.
    hp_get_manifest || return 1
    if [[ "${installed}" != "${HP_VERSION}" ]] && ! hp_newer "${HP_VERSION}" "${installed}"; then
        hp_error 'Refusing a downgrade. Use --rollback to restore the recorded backup.'; return 1
    fi
    hp_get_candidate || return 1
    if [[ "${installed}" == "${HP_VERSION}" && "${original_hash}" == "${HP_SHA}" ]]; then
        printf 'Already installed: %s\n' "${installed}"
        if [[ "${HP_DRY_RUN}" == 0 ]]; then hp_finish_install || return 1; fi
        return 0
    fi
    if [[ "${installed}" == "${HP_VERSION}" && "${HP_ALLOW_MODIFIED}" == 0 ]]; then
        hp_error 'Same version has different contents; use --allow-modified after review.'; return 1
    fi
    printf 'Target: %s\nVersion: %s -> %s\nOwner: %s:%s; mode: %s\nSHA-256: %s\n' \
        "${HP_TARGET}" "${installed}" "${HP_VERSION}" "${uid}" "${gid}" "${mode}" "${HP_SHA}"
    [[ -n "${recorded}" ]] || printf 'Legacy/unmanaged installation: no prior managed checksum; the original file will be backed up.\n'
    if [[ "${HP_DRY_RUN}" == 1 ]]; then printf 'Dry run: verified; installed file and configuration unchanged.\n'; return 0; fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    backup="backup-${stamp}-${BASHPID}.sh"
    cp -- "${HP_TARGET_FILE}" "${HP_PRIVATE}/${backup}" || return 1
    chmod 0600 "${HP_PRIVATE}/${backup}" || return 1
    [[ "$(hp_sha256 "${HP_PRIVATE}/${backup}")" == "${original_hash}" ]] || { hp_error 'Target changed before backup completed; installation stopped.'; return 1; }
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "${backup}" "${original_hash}" "${HP_SHA}" "${uid}" "${gid}" "${mode}" "${installed}" > "${HP_WORK}/rollback" || return 1
    hp_publish_file "${HP_WORK}/rollback" "${HP_PRIVATE}/rollback" || return 1
    hp_install_file "${HP_WORK}/candidate" "${uid}" "${gid}" "${mode}" "${original_hash}" || return 1
    printf 'Installed %s. Backup: %s\n' "${HP_VERSION}" "${HP_PRIVATE}/${backup}"
    hp_finish_install
}

hp_rollback() {
    local -a record
    local backup old_hash new_hash uid gid mode version current
    [[ -f "${HP_PRIVATE}/rollback" && ! -L "${HP_PRIVATE}/rollback" ]] || { hp_error 'No managed backup is recorded.'; return 1; }
    mapfile -t record < "${HP_PRIVATE}/rollback"
    [[ "${#record[@]}" == 7 ]] || return 1
    backup="${record[0]}" old_hash="${record[1]}" new_hash="${record[2]}"
    uid="${record[3]}" gid="${record[4]}" mode="${record[5]}" version="${record[6]}"
    [[ "${backup}" =~ ^backup-[0-9]{8}T[0-9]{6}Z-[0-9]+\.sh$ && "${old_hash}" =~ ^[a-f0-9]{64}$ && "${new_hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "${uid}" =~ ^[0-9]+$ && "${gid}" =~ ^[0-9]+$ && "${mode}" =~ ^[0-7]{3}$ ]] || return 1
    [[ ! -L "${HP_PRIVATE}/${backup}" && "$(hp_sha256 "${HP_PRIVATE}/${backup}")" == "${old_hash}" ]] || { hp_error 'Backup checksum mismatch.'; return 1; }
    [[ "$(hp_read_version "${HP_PRIVATE}/${backup}")" == "${version}" ]] || return 1
    bash -n "${HP_PRIVATE}/${backup}" || return 1
    current="$(hp_sha256 "${HP_TARGET_FILE}")" || return 1
    if [[ "${current}" == "${old_hash}" ]]; then printf 'Backup version is already installed.\n'; return 0; fi
    [[ "${current}" == "${new_hash}" || "${HP_ALLOW_MODIFIED}" == 1 ]] || { hp_error 'Current file differs from the installed release; inspect or use --allow-modified.'; return 1; }
    if [[ "${HP_DRY_RUN}" == 1 ]]; then printf 'Dry run: verified rollback to %s.\n' "${version}"; return 0; fi
    hp_install_file "${HP_PRIVATE}/${backup}" "${uid}" "${gid}" "${mode}" "${current}" || return 1
    printf '%s\n' "${old_hash}" > "${HP_WORK}/receipt" || return 1
    hp_publish_file "${HP_WORK}/receipt" "${HP_PRIVATE}/installed-sha256" || return 1
    hp_sync_flag || return 1
    printf 'Restored %s; configuration unchanged.\n' "${version}"
}

hp_main() (
    umask 077
    local mode="$1"; shift
    local HP_TARGET="" HP_STATE_ROOT=/var/lib/host-pushover HP_RELEASE="" HP_RELEASE_DIR=""
    local HP_REFRESH=0 HP_DRY_RUN=0 HP_ALLOW_MODIFIED=0 HP_SCHEDULE="${HP_BOOTSTRAP}"
    local HP_STATE HP_PRIVATE HP_ID HP_WORK="" HP_STAGE="" HP_LOCKED=0
    local HP_TARGET_FILE HP_TARGET_META HP_PARENT_ID
    local HP_VERSION="" HP_SHA="" HP_BOOTSTRAP_SHA="" HP_HTTP="" HP_ETAG=""
    local cmd missing=()
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --target|--state-dir|--release|--release-dir)
                [[ "$#" -ge 2 && -n "$2" ]] || { hp_error "Missing value for $1"; return 2; }
                case "$1" in
                    --target) HP_TARGET="$2" ;;
                    --state-dir) HP_STATE_ROOT="$2" ;;
                    --release) HP_RELEASE="$2" ;;
                    --release-dir) HP_RELEASE_DIR="$2" ;;
                esac
                shift 2 ;;
            --refresh) HP_REFRESH=1; shift ;;
            --dry-run) HP_DRY_RUN=1; shift ;;
            --allow-modified) HP_ALLOW_MODIFIED=1; shift ;;
            --no-schedule) HP_SCHEDULE=0; shift ;;
            --install-check-schedule) HP_SCHEDULE=1; shift ;;
            *) hp_error "Unknown update option: $1"; return 2 ;;
        esac
    done
    case "${mode}" in check|status|update|rollback|schedule) ;; *) return 2 ;; esac
    if [[ "${mode}" != status && "${EUID}" != 0 ]]; then hp_error 'This operation requires root.'; return 1; fi
    [[ -z "${HP_RELEASE}" ]] || hp_valid_version "${HP_RELEASE}" || { hp_error 'Use a stable numeric release such as 2.0.0.'; return 2; }
    if [[ "${mode}" != update && ( -n "${HP_RELEASE}" || -n "${HP_RELEASE_DIR}" ) ]]; then hp_error 'Release selection is only valid with --update.'; return 2; fi
    if [[ "${HP_REFRESH}" == 1 && "${mode}" != check ]]; then hp_error '--refresh requires --check-update.'; return 2; fi
    if [[ "${mode}" != update && "${mode}" != rollback && ( "${HP_DRY_RUN}" == 1 || "${HP_ALLOW_MODIFIED}" == 1 ) ]]; then hp_error '--dry-run/--allow-modified require update or rollback.'; return 2; fi
    for cmd in stat sha256sum date; do command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}"); done
    if [[ "${mode}" != status ]]; then
        for cmd in bash cp mv mkdir rmdir mktemp chmod chown rm; do command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}"); done
        if [[ ( "${mode}" == update || "${mode}" == check ) && -z "${HP_RELEASE_DIR}" ]]; then
            command -v curl >/dev/null 2>&1 || missing+=(curl)
        fi
    fi
    [[ "${#missing[@]}" == 0 ]] || { hp_error "Missing commands: ${missing[*]}"; return 1; }
    if [[ -z "${HP_TARGET}" ]]; then
        [[ "${HP_BOOTSTRAP}" == 0 ]] || { hp_error 'Bootstrap requires --target pointing to the existing installed script.'; return 2; }
        HP_TARGET="${SCRIPT_PATH}"
    fi
    HP_TARGET="$(hp_target_path "${HP_TARGET}")" || { hp_error 'Target must be an existing regular script, without a final symlink or multiple hard links.'; return 1; }
    if [[ -n "${HP_RELEASE_DIR}" ]]; then
        HP_RELEASE_DIR="$(cd -P -- "${HP_RELEASE_DIR}" && pwd -P)" || return 1
    fi
    cd -P -- "${HP_TARGET%/*}" || return 1
    [[ "$(pwd -P)" == "${HP_TARGET%/*}" ]] || { hp_error 'Target parent changed during resolution.'; return 1; }
    HP_TARGET_FILE="./${HP_TARGET##*/}"
    HP_PARENT_ID="$(stat -c '%d:%i' .)" || return 1
    HP_TARGET_META="$(stat -c '%d:%i:%u:%g:%a:%h' "${HP_TARGET_FILE}")" || return 1
    hp_read_version "${HP_TARGET_FILE}" >/dev/null || { hp_error 'Unrecognized target script/version.'; return 1; }
    [[ "${HP_STATE_ROOT}" == /* && "${HP_STATE_ROOT}" != / && "${HP_STATE_ROOT}" != *'/../'* && "${HP_STATE_ROOT}" != */.. && "${HP_STATE_ROOT}" != *'/./'* ]] || { hp_error 'State directory must be a canonical absolute path.'; return 2; }
    HP_STATE_ROOT="${HP_STATE_ROOT%/}"
    HP_ID="$(printf '%s' "${HP_TARGET}" | sha256sum)" || return 1
    HP_ID="${HP_ID%% *}"
    HP_STATE="${HP_STATE_ROOT}/${HP_ID}"
    HP_PRIVATE="${HP_STATE}/private"
    if [[ "${mode}" == status ]]; then hp_status; return $?; fi
    trap hp_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    hp_make_state || return 1
    case "${mode}" in
        check) hp_check ;;
        update) hp_update ;;
        rollback) hp_rollback ;;
        schedule) hp_schedule ;;
    esac
)

bootstrap_main() {
    local mode=update
    case "${1:-}" in
        --help|-h|"")
            cat <<'HELP'
Upgrade an existing host-pushover installation to a unified release.

Usage: upgrade-host-pushover.sh --target <installed-script> [options]
       upgrade-host-pushover.sh --rollback --target <installed-script>

Run as root. Options:
  --dry-run             Download and verify without replacing the installed script
  --release <version>   Pin a stable release, for example 2.0.0
  --release-dir <dir>   Use a local release bundle for an offline pilot
  --state-dir <dir>     Root-owned updater state (default: /var/lib/host-pushover)
  --allow-modified      Explicitly replace a locally edited managed installation
  --no-schedule         Skip automatic cron setup / DSM scheduling instructions

The original script is backed up. Pushover configuration and existing callers
are preserved. Symlinked directories are resolved; final script symlinks and
multiple hard links are refused. DSM receives the same script as other Linux.
HELP
            return 0 ;;
        --rollback) mode=rollback; shift ;;
    esac
    hp_main "${mode}" "$@"
}
bootstrap_main "$@"
