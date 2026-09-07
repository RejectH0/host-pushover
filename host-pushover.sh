#!/usr/bin/env bash
# Host-aware Pushover delivery helper. See README.md for usage and configuration.
# Release history: CHANGELOG.md. Planned work: TODO.md.

set -u
set -o pipefail
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'host-pushover requires Bash 4.4 or newer.\n' >&2
    exit 1
fi

readonly SCRIPT_NAME="host-pushover.sh"
readonly SCRIPT_VERSION="2.2.0"

readonly SCRIPT_PATH="${BASH_SOURCE[0]}"
PROFILE="auto"
CONFIG_ROOT_DIR=""
CONFIG_FILE=""
APPS_DIR=""
CONFIG_DIR_MODE="0755"
CONFIG_FILE_MODE="0644"
DO_VERSION=0
DO_CHECK_IN=0
DO_PATHS=0
DO_DOCTOR=0
DO_HELP=0
UPDATE_MODE=""
UPDATE_ARGS=()

#-----------------------------#
# Defaults (overridden by config)
#-----------------------------#
PUSHOVER_ENABLED="true"
PUSHOVER_API_URL="https://api.pushover.net/1/messages.json"
PUSHOVER_VALIDATE_URL="https://api.pushover.net/1/users/validate.json"
PUSHOVER_APP_TOKEN=""
PUSHOVER_RECIPIENT_KEY=""
PUSHOVER_DEVICE=""
PUSHOVER_PRIORITY="0"
PUSHOVER_SOUND=""
PUSHOVER_CONNECT_TIMEOUT="10"
PUSHOVER_MAX_TIME="30"
PUSHOVER_HOST_LABEL=""
PUSHOVER_RETRY_ATTEMPTS="1"
PUSHOVER_RETRY_INITIAL_DELAY="5"
PUSHOVER_RETRY_MAX_DELAY="30"

APP_PUSHOVER_ENABLED="true"
APP_PUSHOVER_DEBUG="false"
APP_PUSHOVER_TITLE_PREFIX=""
APP_PUSHOVER_FAILURE_PRIORITY="1"
APP_PUSHOVER_DEBUG_PRIORITY="0"
APP_PUSHOVER_SOUND=""
APP_PUSHOVER_DEVICE=""

#-----------------------------#
# Runtime arguments
#-----------------------------#
CALLER=""
LEVEL=""
MESSAGE=""
TITLE=""
DO_VALIDATE=0
FORCE_SEND=0
DO_SETUP=0
DO_TEST=0

AUTO_SETUP_RAN=0
SETUP_SENT_TEST=0

#-----------------------------#
# Setup workflow state
#-----------------------------#
SETUP_APP_TOKEN=""
SETUP_RECIPIENT_KEY=""
SETUP_DEVICE=""
SETUP_SOUND=""
SETUP_CONNECT_TIMEOUT=""
SETUP_MAX_TIME=""
SETUP_HOST_LABEL=""

#-----------------------------#
# Interactive terminal / ANSI colors
#-----------------------------#
INTERACTIVE=0
if [[ -t 0 && -t 1 ]]; then
    INTERACTIVE=1
fi

if [[ -t 1 || -t 2 ]]; then
    C_RESET=$'\033[0m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

#-----------------------------#
# Utility functions
#-----------------------------#
detect_profile() {
    # File markers are independent of DSM model, version, architecture, and user.
    local etc_dir="${1:-/etc}"
    if [[ -f "${etc_dir}/synoinfo.conf" || -f "${etc_dir}.defaults/synoinfo.conf" ]]; then
        printf 'dsm\n'
    else
        printf 'system\n'
    fi
}

resolve_effective_home() {
    local _account _unused account_uid _account_gid _gecos account_home _account_shell
    # Do not accept a scheduler's inherited HOME belonging to another account.
    if [[ -n "${HOME:-}" && "${HOME}" == /* && -d "${HOME}" && -O "${HOME}" ]]; then
        printf '%s\n' "${HOME}"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        IFS=: read -r _account _unused account_uid _account_gid _gecos account_home _account_shell \
            < <(getent passwd "${EUID}")
        if [[ "${account_uid:-}" == "${EUID}" && "${account_home:-}" == /* && -d "${account_home}" ]]; then
            printf '%s\n' "${account_home}"
            return 0
        fi
    fi
    while IFS=: read -r _account _unused account_uid _account_gid _gecos account_home _account_shell; do
        if [[ "${account_uid}" == "${EUID}" && "${account_home}" == /* && -d "${account_home}" ]]; then
            printf '%s\n' "${account_home}"
            return 0
        fi
    done < /etc/passwd
    printf 'Cannot resolve a home directory for the executing UID.\n' >&2
    return 1
}

initialize_profile() {
    if [[ "${PROFILE}" == auto ]]; then
        PROFILE="$(detect_profile /etc)" || return 1
    fi
    case "${PROFILE}" in
        system)
            CONFIG_ROOT_DIR="/usr/local/etc/host-pushover"
            ;;
        dsm)
            local effective_home
            effective_home="$(resolve_effective_home)" || return 1
            CONFIG_ROOT_DIR="${effective_home}/.config/host-pushover"
            CONFIG_DIR_MODE="0700"
            CONFIG_FILE_MODE="0600"
            PUSHOVER_RETRY_ATTEMPTS="6"
            umask 077
            ;;
        *) printf 'Unknown profile: %s\n' "${PROFILE}" >&2; return 1 ;;
    esac
    CONFIG_FILE="${CONFIG_ROOT_DIR}/config"
    APPS_DIR="${CONFIG_ROOT_DIR}/apps"
}

usage() {
    cat <<EOF2
Usage:
  ${SCRIPT_NAME} --setup
  ${SCRIPT_NAME} --caller <name> --validate
  ${SCRIPT_NAME} --validate
  ${SCRIPT_NAME} --test [--caller <name>] [--title <text>] [--message <text>]
  ${SCRIPT_NAME} --version | --paths | --check-in
  ${SCRIPT_NAME} --doctor [--profile auto|system|dsm] [--state-dir <path>]
  ${SCRIPT_NAME} --check-update [--refresh] [--no-notify] [--notify-priority -1|0] [--target <path>]
  ${SCRIPT_NAME} --update-status [--human] [--target <path>]
  ${SCRIPT_NAME} --update [--dry-run] [--target <path>]
  ${SCRIPT_NAME} --rollback [--dry-run] [--target <path>]
  ${SCRIPT_NAME} --prune-backups [--dry-run] [--target <path>]
  ${SCRIPT_NAME} --caller <name> --level <level> --message <text>
  ${SCRIPT_NAME} --caller <name> --force-send --level <level> --message <text>

Options:
  --setup       Interactive configuration wizard
  --caller      Application/script identity, e.g. dns-updater
  --level       Log/event level such as info, notice, warn, ok, err
  --message     Message body
  --title       Optional explicit title override
  --validate    Validate effective configuration
  --test        Send a manual test message using the current configuration
  --check-in    Validate configuration and send a versioned health notice
  --version     Print the version without configuration or network access
  --paths       Print the detected profile, execution UID, and configuration paths
  --doctor      Inspect local prerequisites, permissions, and cached updater health
  --profile     auto (default), system, or dsm; normally detected automatically
  --check-update  Root: check GitHub, using the daily cache unless --refresh
  --update-status  Read cached update status without network access
  --human       Show readable update status and dates (with --update-status)
  --no-notify    Suppress update notices for this --check-update invocation
  --notify-priority  Update notice priority: -1 quiet (default), or 0 normal
  --update      Root: verify, back up, and install a newer release
  --rollback    Root: restore the previous managed backup
  --prune-backups  Root: remove superseded script backups after offline verification
  --install-check-schedule  Root: install a daily check or print DSM task instructions
  --target      Installed script path; defaults to this script
  --state-dir   Updater state root; defaults to /var/lib/host-pushover
  --release     Pin an update to a stable version, e.g. 2.0.0
  --release-dir Use a locally prepared release bundle instead of GitHub
  --dry-run     Preview an update, rollback, or backup cleanup without changing scripts/backups
  --allow-modified  Explicitly permit replacing a locally modified managed script
  --force-send  Force delivery even if the level would normally be skipped
  --help        Show this help

Configuration (use --paths to see the resolved locations):
  system: /usr/local/etc/host-pushover/{config,apps/<caller>.conf}
  dsm:    <executing-user-home>/.config/host-pushover/{config,apps/<caller>.conf}

Notes:
  - If the script is run interactively with no arguments and config exists,
    it prints help guidance instead of a raw parser error.
  - If the script is run interactively with no arguments and config is
    missing, it can offer to create the config immediately.
  - If the global config is missing during any other interactive command run,
    the script can offer to create it immediately.
  - Use root for system-profile setup and the notification account for DSM setup.
  - Update checks are scheduled separately; message delivery never queries GitHub.
EOF2
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

log_line() {
    local level="$1"
    local message="$2"
    local color="${C_DIM}"

    case "${level}" in
        info)   color="${C_CYAN}" ;;
        notice) color="${C_BLUE}" ;;
        warn)   color="${C_YELLOW}" ;;
        err)    color="${C_RED}" ;;
        ok)     color="${C_GREEN}" ;;
    esac

    printf '%b[%s] [%s] %s%b\n' \
        "${color}" "$(timestamp)" "${level^^}" "${message}" "${C_RESET}" >&2
}

log_info()   { log_line "info"   "$1"; }
log_notice() { log_line "notice" "$1"; }
log_warn()   { log_line "warn"   "$1"; }
log_error()  { log_line "err"    "$1"; }
log_ok()     { log_line "ok"     "$1"; }

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

is_command_available() {
    command -v "$1" >/dev/null 2>&1
}

sanitize_caller() {
    local raw="$1"

    if [[ ! "${raw}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    printf '%s\n' "${raw}"
}

shell_quote() {
    printf '%q' "$1"
}

script_command_hint() {
    local resolved=""
    resolved="$(command -v "${SCRIPT_NAME}" 2>/dev/null || true)"
    if [[ -n "${resolved}" ]]; then
        printf '%s\n' "${resolved}"
    else
        printf '%s\n' "${SCRIPT_NAME}"
    fi
}

clear_screen() {
    if [[ "${INTERACTIVE}" -ne 1 ]]; then
        return 0
    fi

    if is_command_available clear; then
        clear
    else
        printf '\033[2J\033[H' >&2
    fi
}

press_enter_to_continue() {
    if [[ "${INTERACTIVE}" -ne 1 ]]; then
        return 0
    fi

    printf '%bPress Enter to continue...%b' "${C_DIM}" "${C_RESET}" >&2
    local _discard=""
    IFS= read -r _discard || return 1
    return 0
}

display_value() {
    if [[ -z "${1:-}" ]]; then
        printf '<blank>\n'
    else
        printf '%s\n' "$1"
    fi
}

print_missing_config_guidance() {
    printf 'Global config file missing: %s\n' "${CONFIG_FILE}" >&2
    printf 'This helper cannot run until the per-host global config exists.\n' >&2
    printf 'Initialize it with: %s --setup\n' "$(script_command_hint)" >&2
    printf 'Optional per-application overrides live in: %s/<caller>.conf\n' "${APPS_DIR}" >&2
    printf 'Run setup as the account that will use this configuration (root for the system profile).\n' >&2
    return 0
}

print_help_guidance() {
    printf 'No arguments were provided.\n' >&2
    printf 'For usage information, run: %s --help\n' "$(script_command_hint)" >&2
    if [[ "${INTERACTIVE}" == 1 ]]; then
        hp_main status --target "${SCRIPT_PATH}" 2>/dev/null || true
    fi
    return 0
}

ensure_config_directories() {
    mkdir -p "${CONFIG_ROOT_DIR}" "${APPS_DIR}" || return 1
    chmod "${CONFIG_DIR_MODE}" "${CONFIG_ROOT_DIR}" || return 1
    chmod "${CONFIG_DIR_MODE}" "${APPS_DIR}" || return 1
}

load_global_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        print_missing_config_guidance
        return 1
    fi

    if [[ ! -r "${CONFIG_FILE}" ]]; then
        printf 'Global config exists but is not readable: %s\n' "${CONFIG_FILE}" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    if ! source "${CONFIG_FILE}"; then
        printf 'Unable to load global config file: %s\n' "${CONFIG_FILE}" >&2
        return 1
    fi

    return 0
}

load_existing_config_for_setup() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        if [[ ! -r "${CONFIG_FILE}" ]]; then
            printf 'Existing config exists but is not readable: %s\n' "${CONFIG_FILE}" >&2
            return 1
        fi

        # shellcheck disable=SC1090
        source "${CONFIG_FILE}" || return 1
    fi

    return 0
}

load_app_config() {
    if [[ -z "${CALLER}" ]]; then
        return 0
    fi

    local app_file="${APPS_DIR}/${CALLER}.conf"
    if [[ ! -f "${app_file}" ]]; then
        return 0
    fi

    if [[ ! -r "${app_file}" ]]; then
        printf 'App config exists but is not readable for caller "%s": %s\n' "${CALLER}" "${app_file}" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    if ! source "${app_file}"; then
        printf 'Unable to load app config for caller "%s": %s\n' "${CALLER}" "${app_file}" >&2
        return 1
    fi

    return 0
}

require_dependencies() {
    local missing=()

    for cmd in curl sed tr mktemp grep hostname date cp mkdir chmod rm cat sleep awk; do
        if ! is_command_available "${cmd}"; then
            missing+=("${cmd}")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
        return 1
    fi

    return 0
}

effective_enabled() {
    is_true "${PUSHOVER_ENABLED}" && is_true "${APP_PUSHOVER_ENABLED}"
}

is_placeholder_value() {
    case "${1:-}" in
        ""|__REPLACE_WITH_*__) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_setup_default() {
    if is_placeholder_value "${1:-}"; then
        printf '\n'
    else
        printf '%s\n' "$1"
    fi
}

is_fully_configured() {
    if is_placeholder_value "${PUSHOVER_APP_TOKEN}"; then
        return 1
    fi

    if is_placeholder_value "${PUSHOVER_RECIPIENT_KEY}"; then
        return 1
    fi

    return 0
}

resolve_host_label() {
    if [[ -n "${PUSHOVER_HOST_LABEL}" ]]; then
        printf '%s\n' "${PUSHOVER_HOST_LABEL}"
        return 0
    fi

    local detected=""
    detected="$(hostname -s 2>/dev/null || true)"
    if [[ -z "${detected}" ]]; then
        detected="$(hostname 2>/dev/null || true)"
    fi
    if [[ -z "${detected}" ]]; then
        detected="unknown-host"
    fi

    printf '%s\n' "${detected}"
}

build_title_base() {
    local host_label=""
    host_label="$(resolve_host_label)"

    if [[ -n "${APP_PUSHOVER_TITLE_PREFIX}" ]]; then
        printf '%s [%s] %s\n' "${APP_PUSHOVER_TITLE_PREFIX}" "${host_label}" "${CALLER}"
    else
        printf '[%s] %s\n' "${host_label}" "${CALLER}"
    fi
}

build_effective_title() {
    local lvl="$1"
    local base=""

    if [[ -n "${TITLE}" ]]; then
        printf '%s\n' "${TITLE}"
        return 0
    fi

    base="$(build_title_base)"

    case "${lvl}" in
        err)    printf '%s [FAILURE]\n' "${base}" ;;
        warn)   printf '%s [WARNING]\n' "${base}" ;;
        notice) printf '%s [NOTICE]\n' "${base}" ;;
        ok)     printf '%s [OK]\n' "${base}" ;;
        info)   printf '%s [INFO]\n' "${base}" ;;
        *)      printf '%s [%s]\n' "${base}" "${lvl^^}" ;;
    esac
}

build_effective_priority() {
    local lvl="$1"

    case "${lvl}" in
        err)
            printf '%s\n' "${APP_PUSHOVER_FAILURE_PRIORITY}"
            ;;
        *)
            printf '%s\n' "${APP_PUSHOVER_DEBUG_PRIORITY}"
            ;;
    esac
}

build_effective_sound() {
    if [[ -n "${APP_PUSHOVER_SOUND}" ]]; then
        printf '%s\n' "${APP_PUSHOVER_SOUND}"
    else
        printf '%s\n' "${PUSHOVER_SOUND}"
    fi
}

build_effective_device() {
    if [[ -n "${APP_PUSHOVER_DEVICE}" ]]; then
        printf '%s\n' "${APP_PUSHOVER_DEVICE}"
    else
        printf '%s\n' "${PUSHOVER_DEVICE}"
    fi
}

should_send_for_level() {
    local lvl="$1"

    if ! effective_enabled; then
        return 1
    fi

    if ! is_fully_configured; then
        return 1
    fi

    if [[ "${FORCE_SEND}" -eq 1 ]]; then
        return 0
    fi

    case "${lvl}" in
        err)
            return 0
            ;;
        *)
            if is_true "${APP_PUSHOVER_DEBUG}"; then
                return 0
            fi
            return 1
            ;;
    esac
}

is_transient_curl_exit() {
    case "${1:-}" in
        5|6|7|18|28|35|47|52|55|56)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_transient_http_code() {
    case "${1:-}" in
        408|425|429|500|502|503|504)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

normalized_positive_integer() {
    local value="${1:-}"
    local fallback="$2"

    if [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "${value}"
    else
        printf '%s\n' "${fallback}"
    fi
}

post_urlencoded() {
    local endpoint="$1"
    shift

    local attempts initial_delay max_delay
    attempts="$(normalized_positive_integer "${PUSHOVER_RETRY_ATTEMPTS:-}" "1")"
    initial_delay="$(normalized_positive_integer "${PUSHOVER_RETRY_INITIAL_DELAY:-}" "5")"
    max_delay="$(normalized_positive_integer "${PUSHOVER_RETRY_MAX_DELAY:-}" "30")"

    local attempt=1
    local delay="${initial_delay}"
    local response_file=""
    local http_code=""
    local curl_exit=0
    local response_body=""
    local should_retry=0

    while (( attempt <= attempts )); do
        response_file=""
        if ! response_file="$(mktemp)"; then
            printf '\n1\nmktemp failed while preparing Pushover request\n'
            return 0
        fi

        http_code="$(
            curl -sS \
                --connect-timeout "${PUSHOVER_CONNECT_TIMEOUT}" \
                --max-time "${PUSHOVER_MAX_TIME}" \
                --output "${response_file}" \
                --write-out '%{http_code}' \
                "$@" \
                "${endpoint}"
        )"
        curl_exit=$?

        response_body=""
        if [[ -f "${response_file}" ]]; then
            response_body="$(tr -d '\r' < "${response_file}")"
            rm -f "${response_file}"
        fi

        should_retry=0

        if [[ "${curl_exit}" -ne 0 ]] && is_transient_curl_exit "${curl_exit}"; then
            should_retry=1
        elif [[ "${curl_exit}" -eq 0 ]] && is_transient_http_code "${http_code}"; then
            should_retry=1
        fi

        if [[ "${should_retry}" -eq 0 || "${attempt}" -ge "${attempts}" ]]; then
            printf '%s\n%s\n%s\n' "${http_code}" "${curl_exit}" "${response_body}"
            return 0
        fi

        log_warn "Transient Pushover transport failure on attempt ${attempt}/${attempts}: $(response_summary "${http_code}" "${curl_exit}" "${response_body}" | tr -d '\n')"
        log_notice "Retrying Pushover request in ${delay} seconds."

        sleep "${delay}"

        delay=$(( delay * 2 ))
        if (( delay > max_delay )); then
            delay="${max_delay}"
        fi

        attempt=$(( attempt + 1 ))
    done

    # Defensive fallback; the loop should always return above.
    printf '%s\n%s\n%s\n' "${http_code}" "${curl_exit}" "${response_body}"
}

json_status_is_success() {
    # Parse JSON with POSIX awk rather than matching status text inside another
    # number, a nested object, or an error string. No jq/Python runtime is needed.
    printf '%s' "$1" | awk '
        function ws() { while (substr(s,p,1) ~ /^[ \t\r\n]$/) p++ }
        function str(    c,e,out,h) {
            if (substr(s,p++,1) != "\"") { bad=1; return "" }
            out=""
            while (p <= length(s)) {
                c=substr(s,p++,1)
                if (c == "\"") return out
                if (c ~ /[[:cntrl:]]/) { bad=1; return "" }
                if (c == "\\") {
                    e=substr(s,p++,1)
                    if (e == "u") {
                        h=substr(s,p,4)
                        if (length(h)!=4 || h ~ /[^0-9a-fA-F]/) { bad=1; return "" }
                        p+=4
                        out=out "?"
                    } else if (e ~ /^["\\\/bfnrt]$/) out=out "?"
                    else { bad=1; return "" }
                } else out=out c
            }
            bad=1
            return ""
        }
        function value(depth,    c,key,token,start,number) {
            if (depth > 32) { bad=1; return }
            ws(); c=substr(s,p,1)
            if (c == "{") {
                p++; ws()
                if (substr(s,p,1)=="}") { p++; return }
                while (!bad) {
                    ws(); key=str(); ws()
                    if (substr(s,p++,1)!=":") { bad=1; return }
                    ws(); start=p
                    value(depth+1)
                    token=substr(s,start,p-start)
                    sub(/[ \t\r\n]+$/, "", token)
                    if (depth==0 && key=="status") { count++; success=(token=="1") }
                    ws(); c=substr(s,p++,1)
                    if (c=="}") return
                    if (c!=",") { bad=1; return }
                }
            } else if (c == "[") {
                p++; ws()
                if (substr(s,p,1)=="]") { p++; return }
                while (!bad) {
                    value(depth+1); ws(); c=substr(s,p++,1)
                    if (c=="]") return
                    if (c!=",") { bad=1; return }
                }
            } else if (c == "\"") str()
            else if (match(substr(s,p), /^(true|false|null)/)) p+=RLENGTH
            else if (match(substr(s,p), /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) p+=RLENGTH
            else bad=1
        }
        { s=s $0 "\n" }
        END {
            p=1; ws()
            if (substr(s,p,1)!="{") exit 1
            value(0); ws()
            exit (bad || p<=length(s) || count!=1 || !success)
        }
    '
}

response_summary() {
    local http_code="$1"
    local curl_exit="$2"
    local response_body="$3"

    if [[ -n "${http_code}" ]]; then
        printf 'HTTP=%s curl_exit=%s' "${http_code}" "${curl_exit}"
    else
        printf 'curl_exit=%s' "${curl_exit}"
    fi

    if [[ -n "${response_body}" ]]; then
        printf ' response=%s' "${response_body}"
    fi

    printf '\n'
}

validate_effective_config() {
    if ! effective_enabled; then
        if [[ -n "${CALLER}" ]]; then
            printf 'Notifications are disabled for caller "%s".\n' "${CALLER}"
        else
            printf 'Notifications are globally disabled.\n'
        fi
        return 0
    fi

    if ! is_fully_configured; then
        printf 'Pushover is not fully configured in %s.\n' "${CONFIG_FILE}" >&2
        return 1
    fi

    local effective_device=""
    effective_device="$(build_effective_device)"

    local result=""
    if [[ -n "${effective_device}" ]]; then
        result="$(
            post_urlencoded \
                "${PUSHOVER_VALIDATE_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}" \
                --data-urlencode "device=${effective_device}"
        )"
    else
        result="$(
            post_urlencoded \
                "${PUSHOVER_VALIDATE_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}"
        )"
    fi

    local http_code=""
    local curl_exit=""
    local response_body=""
    http_code="$(printf '%s\n' "${result}" | sed -n '1p')"
    curl_exit="$(printf '%s\n' "${result}" | sed -n '2p')"
    response_body="$(printf '%s\n' "${result}" | sed -n '3,$p')"

    if [[ "${curl_exit}" -ne 0 ]]; then
        printf 'Pushover validation curl failure. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    if [[ ! "${http_code}" =~ ^2 ]]; then
        printf 'Pushover validation failed. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    if ! json_status_is_success "${response_body}"; then
        printf 'Pushover validation returned a non-success payload. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    if [[ -n "${CALLER}" ]]; then
        printf 'Pushover validation succeeded for caller "%s".\n' "${CALLER}"
    else
        printf 'Pushover validation succeeded.\n'
    fi
    return 0
}

send_message() {
    local lvl="$1"
    local msg="$2"

    if ! effective_enabled; then
        return 0
    fi

    if ! is_fully_configured; then
        printf 'Pushover is not fully configured in %s. Run %s --setup\n' "${CONFIG_FILE}" "$(script_command_hint)" >&2
        return 1
    fi

    if ! should_send_for_level "${lvl}"; then
        return 0
    fi

    local effective_title=""
    local effective_priority=""
    local effective_sound=""
    local effective_device=""
    effective_title="$(build_effective_title "${lvl}")"
    effective_priority="$(build_effective_priority "${lvl}")"
    effective_sound="$(build_effective_sound)"
    effective_device="$(build_effective_device)"

    local result=""
    if [[ -n "${effective_device}" && -n "${effective_sound}" ]]; then
        result="$(
            post_urlencoded \
                "${PUSHOVER_API_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}" \
                --data-urlencode "title=${effective_title}" \
                --data-urlencode "message=${msg}" \
                --data-urlencode "priority=${effective_priority}" \
                --data-urlencode "device=${effective_device}" \
                --data-urlencode "sound=${effective_sound}"
        )"
    elif [[ -n "${effective_device}" ]]; then
        result="$(
            post_urlencoded \
                "${PUSHOVER_API_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}" \
                --data-urlencode "title=${effective_title}" \
                --data-urlencode "message=${msg}" \
                --data-urlencode "priority=${effective_priority}" \
                --data-urlencode "device=${effective_device}"
        )"
    elif [[ -n "${effective_sound}" ]]; then
        result="$(
            post_urlencoded \
                "${PUSHOVER_API_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}" \
                --data-urlencode "title=${effective_title}" \
                --data-urlencode "message=${msg}" \
                --data-urlencode "priority=${effective_priority}" \
                --data-urlencode "sound=${effective_sound}"
        )"
    else
        result="$(
            post_urlencoded \
                "${PUSHOVER_API_URL}" \
                --data-urlencode "token=${PUSHOVER_APP_TOKEN}" \
                --data-urlencode "user=${PUSHOVER_RECIPIENT_KEY}" \
                --data-urlencode "title=${effective_title}" \
                --data-urlencode "message=${msg}" \
                --data-urlencode "priority=${effective_priority}"
        )"
    fi

    local http_code=""
    local curl_exit=""
    local response_body=""
    http_code="$(printf '%s\n' "${result}" | sed -n '1p')"
    curl_exit="$(printf '%s\n' "${result}" | sed -n '2p')"
    response_body="$(printf '%s\n' "${result}" | sed -n '3,$p')"

    if [[ "${curl_exit}" -ne 0 ]]; then
        printf 'Pushover send curl failure. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    if [[ ! "${http_code}" =~ ^2 ]]; then
        printf 'Pushover send failed. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    if ! json_status_is_success "${response_body}"; then
        printf 'Pushover send returned a non-success payload. %s' "$(response_summary "${http_code}" "${curl_exit}" "${response_body}")" >&2
        return 1
    fi

    return 0
}

looks_like_pushover_token() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]{30}$ ]]
}

looks_like_pushover_user_or_group_key() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]{30}$ ]]
}

looks_like_pushover_device() {
    [[ -z "${1:-}" || "${1}" =~ ^[A-Za-z0-9_-]{1,25}$ ]]
}

looks_like_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

confirm_yes_no() {
    local prompt_text="$1"
    local default_answer="${2:-y}"
    local reply=""

    while true; do
        if [[ "${default_answer}" == "y" ]]; then
            printf '%b%s%b [Y/n]: ' "${C_CYAN}" "${prompt_text}" "${C_RESET}" >&2
        else
            printf '%b%s%b [y/N]: ' "${C_CYAN}" "${prompt_text}" "${C_RESET}" >&2
        fi

        IFS= read -r reply || return 1
        if [[ -z "${reply}" ]]; then
            reply="${default_answer}"
        fi

        case "${reply}" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) log_warn "Please answer yes or no." ;;
        esac
    done
}

read_visible_value() {
    local __resultvar="$1"
    local prompt_text="$2"
    local input=""

    printf '%b%s%b: ' "${C_CYAN}" "${prompt_text}" "${C_RESET}" >&2
    IFS= read -r input || return 1
    printf -v "${__resultvar}" '%s' "${input}"
    return 0
}

validate_nonempty() {
    [[ -n "${1:-}" ]]
}

validate_any() {
    return 0
}

validate_pushover_token_value() {
    looks_like_pushover_token "$1"
}

validate_pushover_user_key_value() {
    looks_like_pushover_user_or_group_key "$1"
}

validate_device_value() {
    looks_like_pushover_device "$1"
}

validate_integer_value() {
    looks_like_integer "$1"
}

show_setup_intro_screen() {
    clear_screen
    printf '%b%s%b\n\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf 'Config file location: %s\n' "${CONFIG_FILE}" >&2
    printf 'Per-application overrides: %s/<caller>.conf\n\n' "${APPS_DIR}" >&2
    printf '%bSecurity note:%b input is visible while you type so you can confirm pastes and use Backspace/Delete normally.\n' "${C_BOLD}" "${C_RESET}" >&2
    printf 'Before pasting sensitive API keys, make sure nobody else can see your screen.\n\n' >&2
    printf '%bPress Enter to begin the questionnaire.%b\n' "${C_DIM}" "${C_RESET}" >&2
}

show_setup_question_screen() {
    local index="$1"
    local total="$2"
    local label="$3"
    local description="$4"
    local current_value="$5"
    local allow_empty="$6"

    clear_screen
    printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf '%b[%s of %s]%b %s\n\n' "${C_BOLD}" "${index}" "${total}" "${C_RESET}" "${label}" >&2
    printf '%s\n\n' "${description}" >&2

    if [[ -n "${current_value}" ]]; then
        printf 'Current value: %s\n' "$(display_value "${current_value}")" >&2
        printf '%bPress Enter to keep the current value shown above.%b\n' "${C_DIM}" "${C_RESET}" >&2
    elif [[ "${allow_empty}" -eq 1 ]]; then
        printf '%bBlank is allowed for this field.%b\n' "${C_DIM}" "${C_RESET}" >&2
    else
        printf '%bA value is required for this field.%b\n' "${C_DIM}" "${C_RESET}" >&2
    fi

    printf '\n' >&2
}

show_setup_confirmation_screen() {
    local index="$1"
    local total="$2"
    local label="$3"
    local value="$4"

    clear_screen
    printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf '%b[%s of %s]%b Confirm %s\n\n' "${C_BOLD}" "${index}" "${total}" "${C_RESET}" "${label}" >&2
    printf '%bYou entered:%b\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s\n\n' "$(display_value "${value}")" >&2
}

ask_question_with_confirmation() {
    local __resultvar="$1"
    local index="$2"
    local total="$3"
    local label="$4"
    local description="$5"
    local current_value="$6"
    local allow_empty="$7"
    local validator_fn="$8"
    local validation_message="$9"
    local validation_mode="${10}"

    local candidate=""

    while true; do
        show_setup_question_screen "${index}" "${total}" "${label}" "${description}" "${current_value}" "${allow_empty}"
        read_visible_value candidate "${label}" || return 1

        if [[ -z "${candidate}" ]]; then
            candidate="${current_value}"
        fi

        if [[ "${allow_empty}" -eq 0 && -z "${candidate}" ]]; then
            log_warn "A value is required."
            press_enter_to_continue || return 1
            continue
        fi

        if [[ -n "${validator_fn}" ]] && ! "${validator_fn}" "${candidate}"; then
            case "${validation_mode}" in
                strict)
                    log_warn "${validation_message}"
                    press_enter_to_continue || return 1
                    continue
                    ;;
                warn)
                    log_warn "${validation_message}"
                    if ! confirm_yes_no "Keep this value anyway" "n"; then
                        continue
                    fi
                    ;;
            esac
        fi

        show_setup_confirmation_screen "${index}" "${total}" "${label}" "${candidate}"
        if confirm_yes_no "Is this correct" "y"; then
            printf -v "${__resultvar}" '%s' "${candidate}"
            return 0
        fi
    done
}

setup_question_count() {
    printf '7\n'
}

ask_setup_question_by_number() {
    local question_number="$1"
    local total=""
    total="$(setup_question_count)"

    case "${question_number}" in
        1)
            ask_question_with_confirmation \
                SETUP_APP_TOKEN \
                "1" "${total}" \
                "Pushover application token" \
                "Paste the 30-character application token for the Pushover application that will send notifications." \
                "${SETUP_APP_TOKEN}" \
                0 \
                "validate_pushover_token_value" \
                "This does not look like a standard 30-character Pushover application token." \
                "warn"
            ;;
        2)
            ask_question_with_confirmation \
                SETUP_RECIPIENT_KEY \
                "2" "${total}" \
                "Pushover user or group key" \
                "Paste the 30-character Pushover user key or group key that should receive notifications." \
                "${SETUP_RECIPIENT_KEY}" \
                0 \
                "validate_pushover_user_key_value" \
                "This does not look like a standard 30-character Pushover user or group key." \
                "warn"
            ;;
        3)
            ask_question_with_confirmation \
                SETUP_DEVICE \
                "3" "${total}" \
                "Default device name" \
                "Optional. Leave blank to deliver to all active devices for the configured Pushover user/group. If set, this usually matches a Pushover device name." \
                "${SETUP_DEVICE}" \
                1 \
                "validate_device_value" \
                "This does not look like a typical Pushover device name. Letters, numbers, underscores, and dashes are usually expected." \
                "warn"
            ;;
        4)
            ask_question_with_confirmation \
                SETUP_SOUND \
                "4" "${total}" \
                "Default sound override" \
                "Optional. Leave blank to use the Pushover account's default notification sound." \
                "${SETUP_SOUND}" \
                1 \
                "validate_any" \
                "" \
                "none"
            ;;
        5)
            ask_question_with_confirmation \
                SETUP_CONNECT_TIMEOUT \
                "5" "${total}" \
                "curl connect timeout (seconds)" \
                "Required. Number of seconds curl will wait while establishing a connection to Pushover." \
                "${SETUP_CONNECT_TIMEOUT}" \
                0 \
                "validate_integer_value" \
                "The connect timeout must be an integer number of seconds." \
                "strict"
            ;;
        6)
            ask_question_with_confirmation \
                SETUP_MAX_TIME \
                "6" "${total}" \
                "curl max time (seconds)" \
                "Required. Total number of seconds curl may spend on a Pushover request before timing out." \
                "${SETUP_MAX_TIME}" \
                0 \
                "validate_integer_value" \
                "The max time must be an integer number of seconds." \
                "strict"
            ;;
        7)
            ask_question_with_confirmation \
                SETUP_HOST_LABEL \
                "7" "${total}" \
                "Host label used in notification titles" \
                "Required. This label appears in notification titles so you can tell which machine generated the message." \
                "${SETUP_HOST_LABEL}" \
                0 \
                "validate_nonempty" \
                "The host label cannot be blank." \
                "strict"
            ;;
        *)
            log_error "Unknown setup question number: ${question_number}"
            return 1
            ;;
    esac
}

show_setup_summary_screen() {
    clear_screen
    printf '%b%s%b\n\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf '%bReview the configuration values below.%b\n' "${C_BOLD}" "${C_RESET}" >&2
    printf 'Enter a number to edit that answer, W to write the config file, or C to cancel.\n\n' >&2
    printf '  1. Pushover application token: %s\n' "$(display_value "${SETUP_APP_TOKEN}")" >&2
    printf '  2. Pushover user or group key: %s\n' "$(display_value "${SETUP_RECIPIENT_KEY}")" >&2
    printf '  3. Default device name: %s\n' "$(display_value "${SETUP_DEVICE}")" >&2
    printf '  4. Default sound override: %s\n' "$(display_value "${SETUP_SOUND}")" >&2
    printf '  5. curl connect timeout (seconds): %s\n' "$(display_value "${SETUP_CONNECT_TIMEOUT}")" >&2
    printf '  6. curl max time (seconds): %s\n' "$(display_value "${SETUP_MAX_TIME}")" >&2
    printf '  7. Host label used in notification titles: %s\n\n' "$(display_value "${SETUP_HOST_LABEL}")" >&2
}

review_setup_answers() {
    local choice=""

    while true; do
        show_setup_summary_screen
        printf '%bSelection%b [W/c/1-7]: ' "${C_CYAN}" "${C_RESET}" >&2
        IFS= read -r choice || return 1

        if [[ -z "${choice}" ]]; then
            choice="W"
        fi

        case "${choice}" in
            1|2|3|4|5|6|7)
                ask_setup_question_by_number "${choice}" || return 1
                ;;
            w|W|write|WRITE)
                return 0
                ;;
            c|C|cancel|CANCEL)
                return 1
                ;;
            *)
                log_warn "Please enter W, C, or a question number from 1 to 7."
                press_enter_to_continue || return 1
                ;;
        esac
    done
}

backup_existing_config_if_present() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        return 0
    fi

    local backup_path stamp
    stamp="$(date '+%Y%m%d_%H%M%S')" || return 1
    backup_path="${CONFIG_FILE}.bak.${stamp}"
    cp -p "${CONFIG_FILE}" "${backup_path}" || return 1
    log_notice "Existing config backed up to: ${backup_path}"
    return 0
}

write_global_config() {
    local app_token="$1"
    local recipient_key="$2"
    local device="$3"
    local sound="$4"
    local connect_timeout="$5"
    local max_time="$6"
    local host_label="$7"

    ensure_config_directories || return 1
    backup_existing_config_if_present || return 1

    cat > "${CONFIG_FILE}" <<EOF2
#------------------------------------------------------------------------------
# host-pushover.sh global configuration
# Generated by ${SCRIPT_NAME} setup on $(date '+%Y-%m-%d %H:%M:%S %Z')
#------------------------------------------------------------------------------

PUSHOVER_ENABLED=true
PUSHOVER_API_URL=$(shell_quote "${PUSHOVER_API_URL}")
PUSHOVER_VALIDATE_URL=$(shell_quote "${PUSHOVER_VALIDATE_URL}")
PUSHOVER_APP_TOKEN=$(shell_quote "${app_token}")
PUSHOVER_RECIPIENT_KEY=$(shell_quote "${recipient_key}")
PUSHOVER_DEVICE=$(shell_quote "${device}")
PUSHOVER_PRIORITY=$(shell_quote "${PUSHOVER_PRIORITY}")
PUSHOVER_SOUND=$(shell_quote "${sound}")
PUSHOVER_CONNECT_TIMEOUT=$(shell_quote "${connect_timeout}")
PUSHOVER_MAX_TIME=$(shell_quote "${max_time}")
PUSHOVER_HOST_LABEL=$(shell_quote "${host_label}")
EOF2
    local write_exit=$?

    if [[ "${write_exit}" -ne 0 ]]; then
        return 1
    fi

    chmod "${CONFIG_FILE_MODE}" "${CONFIG_FILE}" || return 1
    return 0
}

send_explicit_test_message() {
    local saved_caller="${CALLER}"
    local saved_title="${TITLE}"
    local saved_force_send="${FORCE_SEND}"
    local saved_pushover_enabled="${PUSHOVER_ENABLED}"
    local saved_app_pushover_enabled="${APP_PUSHOVER_ENABLED}"
    local saved_app_pushover_debug="${APP_PUSHOVER_DEBUG}"
    local test_caller="${CALLER}"
    local test_message="${MESSAGE}"

    if [[ -z "${test_caller}" ]]; then
        test_caller="manual-test"
    fi

    if [[ -z "${test_message}" ]]; then
        test_message="Pushover test message from host $(resolve_host_label) via ${SCRIPT_NAME} at $(timestamp)."
    fi

    if [[ -z "${TITLE}" ]]; then
        TITLE="[$(resolve_host_label)] Pushover test"
    fi

    CALLER="${test_caller}"
    FORCE_SEND=1
    PUSHOVER_ENABLED="true"
    APP_PUSHOVER_ENABLED="true"
    APP_PUSHOVER_DEBUG="true"

    log_notice "Validating current configuration before sending a test message..."
    if ! validate_effective_config >/dev/null; then
        CALLER="${saved_caller}"
        TITLE="${saved_title}"
        FORCE_SEND="${saved_force_send}"
        PUSHOVER_ENABLED="${saved_pushover_enabled}"
        APP_PUSHOVER_ENABLED="${saved_app_pushover_enabled}"
        APP_PUSHOVER_DEBUG="${saved_app_pushover_debug}"
        return 1
    fi

    log_notice "Sending a test message..."
    if ! send_message "info" "${test_message}"; then
        CALLER="${saved_caller}"
        TITLE="${saved_title}"
        FORCE_SEND="${saved_force_send}"
        PUSHOVER_ENABLED="${saved_pushover_enabled}"
        APP_PUSHOVER_ENABLED="${saved_app_pushover_enabled}"
        APP_PUSHOVER_DEBUG="${saved_app_pushover_debug}"
        return 1
    fi

    CALLER="${saved_caller}"
    TITLE="${saved_title}"
    FORCE_SEND="${saved_force_send}"
    PUSHOVER_ENABLED="${saved_pushover_enabled}"
    APP_PUSHOVER_ENABLED="${saved_app_pushover_enabled}"
    APP_PUSHOVER_DEBUG="${saved_app_pushover_debug}"

    log_ok "Test message sent successfully."
    return 0
}

initialize_setup_defaults() {
    local detected_host_label=""
    detected_host_label="$(resolve_host_label)"

    SETUP_APP_TOKEN="$(normalize_setup_default "${PUSHOVER_APP_TOKEN:-}")"
    SETUP_RECIPIENT_KEY="$(normalize_setup_default "${PUSHOVER_RECIPIENT_KEY:-}")"
    SETUP_DEVICE="${PUSHOVER_DEVICE:-}"
    SETUP_SOUND="${PUSHOVER_SOUND:-}"
    SETUP_CONNECT_TIMEOUT="${PUSHOVER_CONNECT_TIMEOUT:-10}"
    SETUP_MAX_TIME="${PUSHOVER_MAX_TIME:-30}"
    SETUP_HOST_LABEL="${PUSHOVER_HOST_LABEL:-${detected_host_label}}"
}

run_setup() {
    require_dependencies || return 1

    if [[ "${INTERACTIVE}" -ne 1 ]]; then
        log_error "--setup requires an interactive terminal."
        return 1
    fi

    ensure_config_directories || {
        log_error "Unable to create configuration directories under ${CONFIG_ROOT_DIR}."
        return 1
    }

    if ! load_existing_config_for_setup; then
        log_error "Existing config could not be loaded for setup."
        return 1
    fi

    show_setup_intro_screen
    press_enter_to_continue || return 1

    initialize_setup_defaults

    local question_number=""
    for question_number in 1 2 3 4 5 6 7; do
        ask_setup_question_by_number "${question_number}" || return 1
    done

    if ! review_setup_answers; then
        log_warn "Setup cancelled before writing the config file."
        return 1
    fi

    clear_screen
    printf '%b%s%b\n\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf 'Preparing to write the global config file to: %s\n' "${CONFIG_FILE}" >&2
    printf 'A timestamped backup will be created first if a config file already exists.\n' >&2
    printf 'Configuration directory mode: %s; file mode: %s.\n\n' "${CONFIG_DIR_MODE}" "${CONFIG_FILE_MODE}" >&2

    write_global_config \
        "${SETUP_APP_TOKEN}" \
        "${SETUP_RECIPIENT_KEY}" \
        "${SETUP_DEVICE}" \
        "${SETUP_SOUND}" \
        "${SETUP_CONNECT_TIMEOUT}" \
        "${SETUP_MAX_TIME}" \
        "${SETUP_HOST_LABEL}" || {
        log_error "Unable to write ${CONFIG_FILE}."
        return 1
    }

    if ! load_global_config; then
        log_error "The newly written config could not be reloaded."
        return 1
    fi

    clear_screen
    printf '%b%s%b\n\n' "${C_BOLD}${C_BLUE}" "host-pushover.sh setup" "${C_RESET}" >&2
    printf 'Configuration file written successfully: %s\n' "${CONFIG_FILE}" >&2
    printf 'Optional per-application overrides may be placed under: %s/<caller>.conf\n\n' "${APPS_DIR}" >&2

    SETUP_SENT_TEST=0
    if confirm_yes_no "Would you like to send a test message now" "y"; then
        send_explicit_test_message || return 1
        SETUP_SENT_TEST=1
    else
        log_notice "Test message skipped at user request."
    fi

    return 0
}

ensure_global_config_available() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        if [[ ! -r "${CONFIG_FILE}" ]]; then
            printf 'Global config exists but is not readable: %s\n' "${CONFIG_FILE}" >&2
            return 1
        fi
        return 0
    fi

    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        printf 'Global config file missing: %s\n' "${CONFIG_FILE}" >&2
        printf 'This helper cannot run until the global config has been created.\n' >&2
        if confirm_yes_no 'Should we create it now' 'y'; then
            run_setup || return 1
            AUTO_SETUP_RAN=1
            if [[ -f "${CONFIG_FILE}" ]]; then
                return 0
            fi
        fi

        printf 'Configuration was not created. %s cannot continue without a global config.\n' "${SCRIPT_NAME}" >&2
        print_missing_config_guidance
        return 1
    fi

    print_missing_config_guidance
    return 1
}

handle_no_arguments() {
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        if [[ -f "${CONFIG_FILE}" ]]; then
            if [[ ! -r "${CONFIG_FILE}" ]]; then
                printf 'Global config exists but is not readable: %s
' "${CONFIG_FILE}" >&2
                return 1
            fi

            print_help_guidance
            return 0
        fi

        ensure_global_config_available
        return $?
    fi

    if [[ -f "${CONFIG_FILE}" ]]; then
        if [[ ! -r "${CONFIG_FILE}" ]]; then
            printf 'Global config exists but is not readable: %s
' "${CONFIG_FILE}" >&2
            return 1
        fi

        print_help_guidance
        return 1
    fi

    print_missing_config_guidance
    return 1
}

notification_account() {
    local wanted="$1" entry="" account _secret uid gid _gecos account_home _shell
    if command -v getent >/dev/null 2>&1; then entry="$(getent passwd "${wanted}" 2>/dev/null || true)"; fi
    if [[ -z "${entry}" ]]; then
        while IFS=: read -r account _secret uid gid _gecos account_home _shell; do
            if [[ "${uid}" == "${wanted}" ]]; then
                printf '%s:%s:%s:%s\n' "${account}" "${uid}" "${gid}" "${account_home}"
                return 0
            fi
        done < /etc/passwd
        return 1
    fi
    IFS=: read -r account _secret uid gid _gecos account_home _shell <<< "${entry}"
    [[ "${uid}" == "${wanted}" && "${gid}" =~ ^[0-9]+$ && "${account_home}" == /* ]] || return 1
    printf '%s:%s:%s:%s\n' "${account}" "${uid}" "${gid}" "${account_home}"
}

dispatch_update_notice() {
    local profile uid=0 account account_uid _account_gid account_home entry
    local -a notice_command
    profile="$(detect_profile /etc)" || return 4
    if [[ "${profile}" == dsm ]]; then uid="$(stat -c %u "${HP_TARGET_FILE}")" || return 4; fi
    entry="$(notification_account "${uid}")" || return 4
    IFS=: read -r account account_uid _account_gid account_home <<< "${entry}"
    [[ "${account_uid}" == "${uid}" && "${account_home}" == /* && -d "${account_home}" ]] || return 4
    [[ "$(stat -Lc %u "${account_home}")" == "${uid}" ]] || return 4
    # The parent opens the verified root-owned source; the child creates its own
    # source pipe after changing UID. No user-writable installed code runs as root.
    notice_command=(env -i "PATH=${PATH}" "HOME=${account_home}" "USER=${account}" "LOGNAME=${account}" LC_ALL=C
        "${BASH}" --noprofile --norc -c 'source <(cat) "$@"' host-pushover-notice
        --internal-update-notice "${uid}" "${profile}" "$1" "$2" "${HP_TARGET}" "${HP_STATE_ROOT}" "${HP_NOTICE_PRIORITY}")
    if [[ "${uid}" != 0 ]]; then
        if command -v runuser >/dev/null 2>&1; then
            notice_command=(runuser -u "${account}" -- "${notice_command[@]}")
        elif command -v sudo >/dev/null 2>&1; then
            notice_command=(sudo -n -u "#${uid}" -- "${notice_command[@]}")
        else return 4; fi
    fi
    "${notice_command[@]}" < "${HP_PRIVATE}/checker.sh"
}

send_update_notice() {
    # Internal delivery entrypoint. It cannot check GitHub or install anything.
    [[ "$#" == 7 ]] || return 2
    local expected_uid="$1" installed="$3" available="$4" target="$5" state_root="$6" priority="$7"
    [[ "${expected_uid}" == "${EUID}" && ( "$2" == system || "$2" == dsm ) ]] || return 2
    hp_newer "${available}" "${installed}" || return 2
    [[ "${priority}" == -1 || "${priority}" == 0 ]] || return 2
    local PROFILE="$2"
    initialize_profile || return 1
    require_dependencies || return 1
    load_global_config || return 1
    CALLER=host-pushover-update
    load_app_config || return 1
    effective_enabled || return 3
    is_fully_configured || return 1
    local host_label command_hint
    host_label="$(resolve_host_label)"
    printf -v command_hint '/bin/bash %q --update --target %q --state-dir %q' "${target}" "${target}" "${state_root}"
    TITLE="[${host_label}] host-pushover update available"
    FORCE_SEND=1
    APP_PUSHOVER_DEBUG_PRIORITY="${priority}"
    PUSHOVER_RETRY_ATTEMPTS=1
    send_message notice "host=${host_label}; installed=${installed}; available=${available}. Run as root: ${command_hint}"
}

doctor_result() {
    printf '%s %s\n' "$1" "$2"
    case "$1" in FAIL) doctor_failures=$((doctor_failures + 1)) ;; WARN) doctor_warnings=$((doctor_warnings + 1)) ;; esac
}

doctor_permissions() {
    local path="$1" expected_mode="$2" expected_uid="$3" description="$4" metadata uid mode
    if [[ ! -e "${path}" ]]; then doctor_result FAIL "${description}: missing"; return 0; fi
    if [[ -L "${path}" ]]; then doctor_result WARN "${description}: symbolic link; inspect its destination"; return 0; fi
    if ! metadata="$(stat -c '%u:%a' "${path}" 2>/dev/null)"; then doctor_result FAIL "${description}: metadata inaccessible"; return 0; fi
    IFS=: read -r uid mode <<< "${metadata}"
    if [[ "${uid}" != "${expected_uid}" ]] || (( (8#${mode} & ~8#${expected_mode}) != 0 )); then
        doctor_result WARN "${description}: owner UID ${uid}, mode ${mode}; expected UID ${expected_uid} with permissions no broader than ${expected_mode}"
    else doctor_result PASS "${description}: owner UID ${uid}, mode ${mode}"; fi
}

run_doctor() {
    local doctor_failures=0 doctor_warnings=0 cmd expected_uid=0 curl_info curl_version status line cache=unknown
    local target="${SCRIPT_PATH}" state_root=/var/lib/host-pushover
    local -a missing=()
    while (( $# )); do
        case "$1" in
            --target) target="$2"; shift 2 ;;
            --state-dir) state_root="$2"; shift 2 ;;
            *) printf 'Doctor accepts only --profile, --target, and --state-dir.\n' >&2; return 2 ;;
        esac
    done
    printf 'host-pushover %s local diagnostics\n' "${SCRIPT_VERSION}"
    doctor_result PASS "Bash ${BASH_VERSION} (minimum 4.4)"
    if ! initialize_profile; then doctor_result FAIL 'Profile/home resolution failed'; return 1; fi
    doctor_result PASS "Execution UID ${EUID}; profile ${PROFILE}"
    printf 'Configuration path: %s\n' "${CONFIG_FILE}"
    if [[ "${PROFILE}" == dsm ]]; then
        expected_uid="${EUID}"
        printf 'Resolved notification home: %s\n' "${CONFIG_ROOT_DIR%/.config/host-pushover}"
    fi
    for cmd in curl sed tr mktemp grep hostname date cp mkdir chmod rm cat sleep awk stat sha256sum chown rmdir mv; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} )); then doctor_result FAIL "Missing utilities: ${missing[*]}"
    else doctor_result PASS 'Required notification and update utilities are available'; fi
    if command -v curl >/dev/null 2>&1; then
        curl_info="$(curl --disable --version 2>/dev/null)"
        if [[ "${curl_info}" =~ ^curl[[:space:]]([0-9.]+) ]]; then curl_version="${BASH_REMATCH[1]}"; else curl_version=unknown; fi
        if [[ "${curl_info}" =~ (^|[[:space:]])https([[:space:]]|$) ]]; then doctor_result PASS "curl ${curl_version} supports HTTPS"
        else doctor_result FAIL 'curl does not report HTTPS support'; fi
    fi
    if [[ -f "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]]; then doctor_result PASS 'Global configuration is readable (contents were not loaded)'
    else doctor_result FAIL 'Global configuration is missing or unreadable'; fi
    if command -v stat >/dev/null 2>&1; then
        doctor_permissions "${CONFIG_ROOT_DIR}" "${CONFIG_DIR_MODE}" "${expected_uid}" 'Configuration directory'
        doctor_permissions "${CONFIG_FILE}" "${CONFIG_FILE_MODE}" "${expected_uid}" 'Configuration file'
        doctor_permissions "${APPS_DIR}" "${CONFIG_DIR_MODE}" "${expected_uid}" 'Caller configuration directory'
        if [[ "${PROFILE}" == dsm && -f "${target}" && "$(stat -c %u "${target}")" != "${EUID}" ]]; then
            doctor_result WARN 'The installation belongs to another UID; run diagnostics as its notification account'
        fi
    fi
    if [[ -d /proc/self/fd ]]; then doctor_result PASS 'Directory descriptor support is available'
    else doctor_result FAIL '/proc/self/fd is unavailable for atomic updates'; fi
    if [[ "${PROFILE}" == dsm ]]; then
        if command -v runuser >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1; then doctor_result PASS 'An account-switch utility is available for scheduled notices'
        else doctor_result WARN 'Scheduled update notices need runuser or sudo to use the notification account'; fi
    fi
    if status="$(hp_main status --target "${target}" --state-dir "${state_root}" 2>/dev/null)"; then
        while IFS= read -r line; do case "${line}" in cache=*) cache="${line#*=}" ;; esac; done <<< "${status}"
        if [[ "${cache}" == fresh ]]; then doctor_result PASS 'Cached update information is fresh'
        else doctor_result WARN "Cached update information is ${cache}; use --check-update --refresh as root for an online check"; fi
    else doctor_result FAIL 'Installed target or updater state could not be inspected'; fi
    printf 'Result: %s failure(s), %s warning(s). No configuration code was loaded; no network requests or notifications were made.\n' "${doctor_failures}" "${doctor_warnings}"
    (( doctor_failures == 0 ))
}

# BEGIN UPDATE ENGINE
# The release builder extracts this block to generate the standalone bootstrap.
# Keep it independent of Pushover settings and never source downloaded metadata.
readonly HP_REPOSITORY="RejectH0/host-pushover"
readonly HP_BOOTSTRAP=0

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
        if [[ "${rc}" != 0 ]]; then HP_FAILURE="curl:${rc}"
        elif [[ "${code}" =~ ^[0-9]{3}$ ]]; then HP_FAILURE="http:${code}"
        else HP_FAILURE=download; fi
        hp_error "Download failed (curl=${rc}, HTTP=${code:-unknown})."; return 1;
    }
    if [[ "${code}" == 200 ]]; then
        [[ -f "${dest}" && "$(stat -c %s "${dest}")" -le "${limit}" ]] || { HP_FAILURE=size; return 1; }
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
    hp_parse_manifest "${HP_WORK}/manifest" || { HP_FAILURE=manifest; hp_error 'Invalid release manifest.'; return 1; }
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

hp_read_small() {
    local value=""
    if [[ -f "$1" && ! -L "$1" && "$(stat -c %s "$1")" -le 80 ]]; then
        IFS= read -r value < "$1" || true
    fi
    printf '%s' "${value}"
}

hp_readable_time() {
    if [[ "$1" == 0 ]]; then printf 'not recorded'; return 0; fi
    date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || printf 'Unix time %s\n' "$1"
}

hp_failure_description() {
    # Persist only controlled error codes, never response bodies or curl stderr.
    case "$1" in
        http:404) printf 'HTTP 404: release manifest not found' ;;
        http:*) [[ "$1" =~ ^http:[0-9]{3}$ ]] && printf 'HTTP %s' "${1#*:}" || printf 'unknown failure' ;;
        curl:28) printf 'Request timed out (curl 28)' ;;
        curl:6) printf 'Hostname lookup failed (curl 6)' ;;
        curl:7) printf 'Connection failed (curl 7)' ;;
        curl:60) printf 'TLS certificate verification failed (curl 60)' ;;
        curl:*) [[ "$1" =~ ^curl:[0-9]{1,3}$ ]] && printf 'Transport failure (curl %s)' "${1#*:}" || printf 'unknown failure' ;;
        manifest) printf 'Release manifest is invalid' ;;
        size) printf 'Release manifest exceeds the size limit' ;;
        *) printf 'Release metadata could not be downloaded or read' ;;
    esac
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
    if [[ "${HP_HUMAN:-0}" == 1 ]]; then
        local last_attempt=0 last_failure=0 error="" notice="" decision
        if hp_trusted_directory "${HP_STATE}"; then
            last_attempt="$(hp_number_file "${HP_STATE}/last-attempt")"
            last_failure="$(hp_number_file "${HP_STATE}/last-failure")"
            error="$(hp_read_small "${HP_STATE}/last-error")"
            notice="$(hp_read_small "${HP_STATE}/notice-status")"
        fi
        case "${flag}" in
            true) decision='Update available' ;;
            false) decision='No newer version in the cached manifest' ;;
            *) decision='Available version is unknown' ;;
        esac
        printf 'Installed version: %s\nLatest known version: %s\nStatus: %s\nCache: %s\n' "${installed}" "${available}" "${decision}" "${freshness}"
        printf 'Last attempt: %s\nLast successful check: %s\nNext eligible check: %s\n' \
            "$(hp_readable_time "${last_attempt}")" "$(hp_readable_time "${last_success}")" "$(hp_readable_time "${next}")"
        if (( last_failure > 0 )); then
            printf 'Last recorded failure: %s; %s\n' "$(hp_readable_time "${last_failure}")" "$(hp_failure_description "${error}")"
        else printf 'Last recorded failure: none\n'; fi
        case "${notice}" in
            sent) printf 'Update notice: accepted by Pushover\n' ;;
            failed) printf 'Update notice: delivery failed; eligible for retry later\n' ;;
            unavailable) printf 'Update notice: verified notifier or account switch is unavailable\n' ;;
            disabled) printf 'Update notice: disabled by existing notification configuration\n' ;;
        esac
        printf 'State directory: %s\n' "${HP_STATE}"
    else
        printf 'installed_version=%s\nlatest_known_version=%s\nupdate_available=%s\ncache=%s\nlast_success=%s\nnext_check=%s\nstate_dir=%s\n' \
        "${installed}" "${available}" "${flag}" "${freshness}" "${last_success}" "${next}" "${HP_STATE}"
    fi
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

hp_maybe_notify() {
    # Discovery owns deduplication state; delivery runs in a separate account.
    [[ "${HP_BOOTSTRAP}" == 0 && "${HP_NOTIFY}" == 1 ]] || return 0
    declare -F dispatch_update_notice >/dev/null || return 0
    local now last_success installed version marker next receipt rc=0
    now="$(date +%s)" || return 0
    last_success="$(hp_number_file "${HP_STATE}/last-success")"
    (( last_success > 0 && now >= last_success && now - last_success < 172800 )) || return 0
    [[ "$(hp_number_file "${HP_STATE}/failures")" == 0 ]] || return 0
    hp_parse_manifest "${HP_STATE}/manifest" || return 0
    version="${HP_VERSION}"
    installed="$(hp_read_version "${HP_TARGET_FILE}")" || return 0
    hp_newer "${version}" "${installed}" || return 0
    marker="${HP_PRIVATE}/notified-${version}"
    [[ ! -e "${marker}" && ! -L "${marker}" ]] || return 0
    next="$(hp_number_file "${HP_STATE}/notice-next")"
    (( next <= now || next - now > 86400 )) || return 0
    receipt="$(hp_read_small "${HP_PRIVATE}/installed-sha256")"
    if [[ ! "${receipt}" =~ ^[a-f0-9]{64}$ || ! -f "${HP_PRIVATE}/checker.sh" || -L "${HP_PRIVATE}/checker.sh" ]] \
        || [[ "$(stat -c '%u:%a' "${HP_PRIVATE}/checker.sh")" != 0:700 ]] \
        || [[ "$(hp_sha256 "${HP_PRIVATE}/checker.sh")" != "${receipt}" ]]; then
        rc=4
    else
        dispatch_update_notice "${installed}" "${version}" > "${HP_WORK}/notice-output" 2>&1 || rc=$?
    fi
    if [[ "${rc}" == 0 ]]; then
        printf '%s\n' "${now}" > "${HP_WORK}/notified" || return 0
        hp_publish_file "${HP_WORK}/notified" "${marker}" || return 0
        hp_write_public notice-status sent || return 0
        hp_write_public notice-next 0 || return 0
    else
        case "${rc}" in
            3) hp_write_public notice-status disabled || return 0 ;;
            4) hp_write_public notice-status unavailable || return 0 ;;
            *) hp_write_public notice-status failed || return 0 ;;
        esac
        hp_write_public notice-next "$((now + 3600))" || return 0
        [[ "${rc}" == 3 ]] || printf 'host-pushover update: update detected; notice was not delivered. See --update-status --human.\n' >&2
    fi
    return 0
}

hp_check() {
    local now next failures delay etag=""
    now="$(date +%s)" || return 1
    next="$(hp_number_file "${HP_STATE}/next-check")"
    if [[ "${HP_REFRESH}" == 0 ]] && (( next > now && next - now <= 86400 )); then
        hp_maybe_notify
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
        hp_write_public last-failure "${now}" || return 1
        hp_write_public last-error "${HP_FAILURE}" || return 1
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
    hp_maybe_notify
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

hp_verify_managed_install() {
    local expected="$1" uid="$2" gid="$3" mode="$4" receipt="${HP_PRIVATE}/installed-sha256" checker="${HP_PRIVATE}/checker.sh"
    [[ "${expected}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ -f "${HP_TARGET_FILE}" && ! -L "${HP_TARGET_FILE}" && "$(stat -c '%u:%g:%a:%h' "${HP_TARGET_FILE}")" == "${uid}:${gid}:${mode}:1" ]] || return 1
    [[ "$(stat -c '%d:%i' "${HP_TARGET%/*}")" == "${HP_PARENT_ID}" && "$(hp_sha256 "${HP_TARGET_FILE}")" == "${expected}" ]] || return 1
    [[ -f "${receipt}" && ! -L "${receipt}" && "$(stat -c '%u:%a:%h' "${receipt}")" == 0:600:1 && "$(hp_read_small "${receipt}")" == "${expected}" ]] || return 1
    [[ -f "${checker}" && ! -L "${checker}" && "$(stat -c '%u:%a:%h' "${checker}")" == 0:700:1 && "$(hp_sha256 "${checker}")" == "${expected}" ]] || return 1
    hp_valid_version "$(hp_read_version "${HP_TARGET_FILE}")" && bash -n "${HP_TARGET_FILE}"
}

hp_prune_backups() {
    local -a record candidates=()
    local rollback="${HP_PRIVATE}/rollback" backup old_hash new_hash uid gid mode version file name size total=0
    # The rollback pointer, not a timestamp or modification time, selects the
    # protected backup. Refuse cleanup if a complete installation cannot be verified.
    if [[ ! -f "${rollback}" || -L "${rollback}" ]] \
        || [[ "$(stat -c '%u:%a:%h' "${rollback}")" != 0:600:1 || "$(stat -c %s "${rollback}")" -gt 1024 ]]; then
        hp_error 'No trusted rollback record; all backups preserved.'; return 1
    fi
    mapfile -t record < "${rollback}"
    [[ "${#record[@]}" == 7 ]] || { hp_error 'Invalid rollback record; all backups preserved.'; return 1; }
    backup="${record[0]}" old_hash="${record[1]}" new_hash="${record[2]}"
    uid="${record[3]}" gid="${record[4]}" mode="${record[5]}" version="${record[6]}"
    if [[ ! "${backup}" =~ ^backup-[0-9]{8}T[0-9]{6}Z-[0-9]+\.sh$ || ! "${old_hash}" =~ ^[a-f0-9]{64}$ || ! "${new_hash}" =~ ^[a-f0-9]{64}$ \
        || ! "${uid}" =~ ^[0-9]+$ || ! "${gid}" =~ ^[0-9]+$ || ! "${mode}" =~ ^[0-7]{3}$ ]]; then
        hp_error 'Invalid rollback metadata; all backups preserved.'; return 1
    fi
    hp_valid_version "${version}" || hp_legacy_version "${version}" || { hp_error 'Invalid rollback version; all backups preserved.'; return 1; }
    file="${HP_PRIVATE}/${backup}"
    if [[ ! -f "${file}" || -L "${file}" ]] || [[ "$(stat -c '%u:%a:%h' "${file}")" != 0:600:1 ]] \
        || [[ "$(hp_sha256 "${file}")" != "${old_hash}" || "$(hp_read_version "${file}")" != "${version}" ]] || ! bash -n "${file}"; then
        hp_error 'Recorded rollback backup failed verification; all backups preserved.'; return 1
    fi
    if ! hp_verify_managed_install "${new_hash}" "${uid}" "${gid}" "${mode}"; then
        hp_error 'Installed script or checker does not match a completed update; all backups preserved.'; return 1
    fi
    printf 'Retaining rollback backup: %s\n' "${file}"
    for file in "${HP_PRIVATE}"/backup-*.sh; do
        name="${file##*/}"
        [[ "${name}" != "${backup}" && "${name}" =~ ^backup-[0-9]{8}T[0-9]{6}Z-[0-9]+\.sh$ ]] || continue
        # Only recognizable root-private script backups are eligible. Leave
        # symlinks, hard links, directories, and unrelated or damaged files alone.
        if [[ ! -f "${file}" || -L "${file}" ]] || [[ "$(stat -c '%u:%a:%h' "${file}")" != 0:600:1 ]] \
            || ! hp_read_version "${file}" >/dev/null || ! bash -n "${file}" 2>/dev/null; then
            printf 'Skipping unrecognized or unsafe backup entry: %s\n' "${name}" >&2
            continue
        fi
        size="$(stat -c %s "${file}")" || return 1
        total=$((total + size))
        candidates+=("${file}")
    done
    if [[ "${HP_DRY_RUN}" == 1 ]]; then
        for file in "${candidates[@]}"; do printf 'Would remove: %s\n' "${file}"; done
        printf 'Dry run: would remove %s superseded backup(s), %s bytes; all backups unchanged.\n' "${#candidates[@]}" "${total}"
        return 0
    fi
    for file in "${candidates[@]}"; do
        rm -- "${file}" || { hp_error 'Backup cleanup incomplete; the recorded rollback backup is retained.'; return 1; }
    done
    printf 'Removed %s superseded backup(s), %s bytes; recorded rollback backup retained.\n' "${#candidates[@]}" "${total}"
}

hp_finish_update() {
    hp_finish_install || return 1
    hp_verify_managed_install "${HP_SHA}" "$1" "$2" "$3" || { hp_error 'Post-install verification failed; all backups preserved.'; return 1; }
    # An already-current unmanaged target may have no rollback record yet.
    if [[ -e "${HP_PRIVATE}/rollback" || -L "${HP_PRIVATE}/rollback" ]]; then
        if ! hp_prune_backups; then
            printf 'Installation verified; backup cleanup needs attention. Inspect --prune-backups --dry-run.\n' >&2
        fi
    fi
    return 0
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
        if [[ "${HP_DRY_RUN}" == 0 ]]; then hp_finish_update "${uid}" "${gid}" "${mode}" || return 1; fi
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
    hp_finish_update "${uid}" "${gid}" "${mode}"
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
    local HP_HUMAN=0 HP_NOTIFY=1 HP_NOTICE_PRIORITY=-1 HP_NOTICE_OPTION=0 HP_FAILURE=download
    local HP_STATE HP_PRIVATE HP_ID HP_WORK="" HP_STAGE="" HP_LOCKED=0
    local HP_TARGET_FILE HP_TARGET_META HP_PARENT_ID
    local HP_VERSION="" HP_SHA="" HP_BOOTSTRAP_SHA="" HP_HTTP="" HP_ETAG=""
    local cmd missing=()
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --target|--state-dir|--release|--release-dir|--notify-priority)
                [[ "$#" -ge 2 && -n "$2" ]] || { hp_error "Missing value for $1"; return 2; }
                case "$1" in
                    --target) HP_TARGET="$2" ;;
                    --state-dir) HP_STATE_ROOT="$2" ;;
                    --release) HP_RELEASE="$2" ;;
                    --release-dir) HP_RELEASE_DIR="$2" ;;
                    --notify-priority) HP_NOTICE_PRIORITY="$2"; HP_NOTICE_OPTION=1 ;;
                esac
                shift 2 ;;
            --refresh) HP_REFRESH=1; shift ;;
            --human) HP_HUMAN=1; shift ;;
            --no-notify) HP_NOTIFY=0; HP_NOTICE_OPTION=1; shift ;;
            --dry-run) HP_DRY_RUN=1; shift ;;
            --allow-modified) HP_ALLOW_MODIFIED=1; shift ;;
            --no-schedule) HP_SCHEDULE=0; shift ;;
            --install-check-schedule) HP_SCHEDULE=1; shift ;;
            *) hp_error "Unknown update option: $1"; return 2 ;;
        esac
    done
    case "${mode}" in check|status|update|rollback|schedule|prune) ;; *) return 2 ;; esac
    if [[ "${HP_HUMAN}" == 1 && "${mode}" != status ]]; then hp_error '--human requires --update-status.'; return 2; fi
    if [[ "${HP_NOTICE_OPTION}" == 1 && "${mode}" != check ]]; then hp_error 'Notification options require --check-update.'; return 2; fi
    [[ "${HP_NOTICE_PRIORITY}" == -1 || "${HP_NOTICE_PRIORITY}" == 0 ]] || { hp_error 'Update notice priority must be -1 or 0.'; return 2; }
    if [[ "${mode}" != status && "${EUID}" != 0 ]]; then hp_error 'This operation requires root.'; return 1; fi
    [[ -z "${HP_RELEASE}" ]] || hp_valid_version "${HP_RELEASE}" || { hp_error 'Use a stable numeric release such as 2.0.0.'; return 2; }
    if [[ "${mode}" != update && ( -n "${HP_RELEASE}" || -n "${HP_RELEASE_DIR}" ) ]]; then hp_error 'Release selection is only valid with --update.'; return 2; fi
    if [[ "${HP_REFRESH}" == 1 && "${mode}" != check ]]; then hp_error '--refresh requires --check-update.'; return 2; fi
    if [[ "${mode}" != update && "${mode}" != rollback && "${mode}" != prune && "${HP_DRY_RUN}" == 1 ]]; then hp_error '--dry-run requires update, rollback, or backup cleanup.'; return 2; fi
    if [[ "${mode}" != update && "${mode}" != rollback && "${HP_ALLOW_MODIFIED}" == 1 ]]; then hp_error '--allow-modified requires update or rollback.'; return 2; fi
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
        prune) hp_prune_backups ;;
        schedule) hp_schedule ;;
    esac
)
# END UPDATE ENGINE

parse_args() {
    local mode_count=0 profile_set=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --caller|--level|--message|--title|--profile)
                [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; return 2; }
                case "$1" in
                    --caller) CALLER="$2" ;;
                    --level) LEVEL="$2" ;;
                    --message) MESSAGE="$2" ;;
                    --title) TITLE="$2" ;;
                    --profile) PROFILE="$2"; profile_set=1 ;;
                esac
                shift 2 ;;
            --setup|--validate|--test|--version|--check-in|--paths|--doctor|--help|-h|--check-update|--update-status|--update|--rollback|--prune-backups|--install-check-schedule)
                mode_count=$((mode_count + 1))
                case "$1" in
                    --setup) DO_SETUP=1 ;;
                    --validate) DO_VALIDATE=1 ;;
                    --test) DO_TEST=1 ;;
                    --version) DO_VERSION=1 ;;
                    --check-in) DO_CHECK_IN=1 ;;
                    --paths) DO_PATHS=1 ;;
                    --doctor) DO_DOCTOR=1 ;;
                    --help|-h) DO_HELP=1 ;;
                    --check-update) UPDATE_MODE=check ;;
                    --update-status) UPDATE_MODE=status ;;
                    --update) UPDATE_MODE=update ;;
                    --rollback) UPDATE_MODE=rollback ;;
                    --prune-backups) UPDATE_MODE=prune ;;
                    --install-check-schedule) UPDATE_MODE=schedule ;;
                esac
                shift ;;
            --target|--state-dir|--release|--release-dir|--notify-priority)
                [[ "$#" -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; return 2; }
                UPDATE_ARGS+=("$1" "$2")
                shift 2 ;;
            --refresh|--dry-run|--allow-modified|--no-schedule|--human|--no-notify)
                UPDATE_ARGS+=("$1")
                shift ;;
            --force-send) FORCE_SEND=1; shift ;;
            *) printf 'Unknown argument: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    if (( mode_count > 1 )); then
        printf 'Use only one standalone command at a time.\n' >&2
        return 2
    fi
    case "${PROFILE}" in auto|system|dsm) ;; *) printf 'Unknown profile: %s\n' "${PROFILE}" >&2; return 2 ;; esac
    if [[ "${DO_DOCTOR}" == 1 ]]; then
        [[ -z "${CALLER}${LEVEL}${MESSAGE}${TITLE}" && "${FORCE_SEND}" == 0 ]] || { printf 'Doctor cannot be combined with notification options.\n' >&2; return 2; }
        return 0
    fi
    if [[ -n "${UPDATE_MODE}" ]]; then
        if [[ -n "${CALLER}${LEVEL}${MESSAGE}${TITLE}" || "${FORCE_SEND}" == 1 || "${profile_set}" == 1 ]]; then
            printf 'Update commands cannot be combined with notification options.\n' >&2
            return 2
        fi
        return 0
    fi
    if (( ${#UPDATE_ARGS[@]} > 0 )); then
        printf 'Update options require an update command.\n' >&2
        return 2
    fi
    if [[ -n "${CALLER}" ]]; then
        CALLER="$(sanitize_caller "${CALLER}")" || { printf 'Invalid caller value.\n' >&2; return 2; }
    fi
    if (( mode_count == 1 )); then return 0; fi
    if [[ -z "${CALLER}" || -z "${LEVEL}" || -z "${MESSAGE}" ]]; then
        printf 'Message delivery requires --caller, --level, and --message.\n' >&2
        return 2
    fi
}

send_health_check_in() {
    local CALLER="health-check" FORCE_SEND=1 PUSHOVER_ENABLED=true
    local APP_PUSHOVER_ENABLED=true APP_PUSHOVER_DEBUG=true
    local host_label TITLE
    host_label="$(resolve_host_label)"
    TITLE="[${host_label}] host-pushover health check"
    validate_effective_config >/dev/null || return 1
    send_message ok "host-pushover ${SCRIPT_VERSION}; host=${host_label}; time=$(timestamp); configuration validated."
}

main() {
    if [[ "${1:-}" == --internal-update-notice ]]; then shift; send_update_notice "$@"; return $?; fi
    if [[ "$#" == 0 ]]; then
        initialize_profile || return 1
        handle_no_arguments
        return $?
    fi
    parse_args "$@" || return $?
    if [[ "${DO_VERSION}" == 1 ]]; then
        printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
        return 0
    fi
    if [[ "${DO_HELP}" == 1 ]]; then usage; return 0; fi
    if [[ "${DO_DOCTOR}" == 1 ]]; then run_doctor "${UPDATE_ARGS[@]}"; return $?; fi
    if [[ -n "${UPDATE_MODE}" ]]; then
        hp_main "${UPDATE_MODE}" "${UPDATE_ARGS[@]}"
        return $?
    fi
    initialize_profile || return 1
    if [[ "${DO_PATHS}" == 1 ]]; then
        printf 'profile=%s\nexecution_uid=%s\nconfig_file=%s\napps_dir=%s\n' \
            "${PROFILE}" "${EUID}" "${CONFIG_FILE}" "${APPS_DIR}"
        return 0
    fi
    if [[ "${DO_SETUP}" == 1 ]]; then run_setup; return $?; fi
    require_dependencies || return 1
    ensure_global_config_available || return 1
    load_global_config || return 1
    if [[ "${DO_CHECK_IN}" == 1 ]]; then send_health_check_in; return $?; fi
    if [[ "${DO_TEST}" == 1 && -z "${CALLER}" ]]; then CALLER="manual-test"; fi
    load_app_config || return 1
    if [[ "${DO_VALIDATE}" == 1 ]]; then validate_effective_config; return $?; fi
    if [[ "${DO_TEST}" == 1 ]]; then
        if [[ "${AUTO_SETUP_RAN}" == 1 && "${SETUP_SENT_TEST}" == 1 ]]; then return 0; fi
        send_explicit_test_message
        return $?
    fi
    send_message "${LEVEL}" "${MESSAGE}"
}

main "$@"
