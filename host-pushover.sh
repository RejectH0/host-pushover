#!/usr/bin/env bash
# Host-aware Pushover delivery helper. See README.md for usage and configuration.
# Release history: CHANGELOG.md. Planned work: TODO.md.

set -u
set -o pipefail

readonly SCRIPT_NAME="host-pushover.sh"
readonly SCRIPT_VERSION="1.04"

readonly CONFIG_ROOT_DIR="/usr/local/etc/host-pushover"
readonly CONFIG_FILE="${CONFIG_ROOT_DIR}/config"
readonly APPS_DIR="${CONFIG_ROOT_DIR}/apps"

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
usage() {
    cat <<EOF2
Usage:
  ${SCRIPT_NAME} --setup
  ${SCRIPT_NAME} --caller <name> --validate
  ${SCRIPT_NAME} --validate
  ${SCRIPT_NAME} --test [--caller <name>] [--title <text>] [--message <text>]
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
  --force-send  Force delivery even if the level would normally be skipped
  --help        Show this help

Global config:
  ${CONFIG_FILE}

Per-application overrides:
  ${APPS_DIR}/<caller>.conf

Notes:
  - If the script is run interactively with no arguments and config exists,
    it prints help guidance instead of a raw parser error.
  - If the script is run interactively with no arguments and config is
    missing, it can offer to create the config immediately.
  - If the global config is missing during any other interactive command run,
    the script can offer to create it immediately.
  - Initial setup usually must be run as root so the system-wide config can
    be written under /usr/local/etc.
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
    printf 'Because the config is stored under /usr/local/etc, initial setup usually must be run as root.\n' >&2
    return 0
}

print_help_guidance() {
    printf 'No arguments were provided.\n' >&2
    printf 'For usage information, run: %s --help\n' "$(script_command_hint)" >&2
    return 0
}

ensure_config_directories() {
    mkdir -p "${CONFIG_ROOT_DIR}" "${APPS_DIR}" || return 1
    chmod 0755 "${CONFIG_ROOT_DIR}" || return 1
    chmod 0755 "${APPS_DIR}" || return 1
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

    for cmd in curl sed tr mktemp grep hostname date cp; do
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

post_urlencoded() {
    local endpoint="$1"
    shift

    local response_file=""
    if ! response_file="$(mktemp)"; then
        printf '\n1\nmktemp failed while preparing Pushover request\n'
        return 0
    fi

    local http_code=""
    local curl_exit=0
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

    local response_body=""
    if [[ -f "${response_file}" ]]; then
        response_body="$(tr -d '\r' < "${response_file}")"
        rm -f "${response_file}"
    fi

    printf '%s\n%s\n%s\n' "${http_code}" "${curl_exit}" "${response_body}"
}

json_status_is_success() {
    local response_body="$1"
    printf '%s' "${response_body}" | tr -d '[:space:]' | grep -q '"status":1'
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

    local backup_path="${CONFIG_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
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

    chmod 0644 "${CONFIG_FILE}" || return 1
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
    printf 'The config directory will be created if needed, and the final file permissions will be set to 0644.\n\n' >&2

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

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --caller)
                [[ "$#" -lt 2 ]] && { printf -- '--caller requires a value\n' >&2; return 1; }
                CALLER="$2"
                shift 2
                ;;
            --level)
                [[ "$#" -lt 2 ]] && { printf -- '--level requires a value\n' >&2; return 1; }
                LEVEL="$2"
                shift 2
                ;;
            --message)
                [[ "$#" -lt 2 ]] && { printf -- '--message requires a value\n' >&2; return 1; }
                MESSAGE="$2"
                shift 2
                ;;
            --title)
                [[ "$#" -lt 2 ]] && { printf -- '--title requires a value\n' >&2; return 1; }
                TITLE="$2"
                shift 2
                ;;
            --validate)
                DO_VALIDATE=1
                shift
                ;;
            --test)
                DO_TEST=1
                shift
                ;;
            --force-send)
                FORCE_SEND=1
                shift
                ;;
            --setup)
                DO_SETUP=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown argument: %s\n' "$1" >&2
                return 1
                ;;
        esac
    done

    if [[ -n "${CALLER}" ]]; then
        CALLER="$(sanitize_caller "${CALLER}")" || {
            printf 'Invalid caller value. Allowed characters: A-Z a-z 0-9 . _ -\n' >&2
            return 1
        }
    fi

    local mode_count=0
    mode_count=$(( DO_SETUP + DO_VALIDATE + DO_TEST ))
    if [[ "${mode_count}" -gt 1 ]]; then
        printf 'Use only one of --setup, --validate, or --test at a time.\n' >&2
        return 1
    fi

    if [[ "${DO_SETUP}" -eq 1 ]]; then
        return 0
    fi

    if [[ "${DO_VALIDATE}" -eq 1 || "${DO_TEST}" -eq 1 ]]; then
        return 0
    fi

    if [[ -z "${CALLER}" ]]; then
        printf -- '--caller is required unless --setup, --validate, or --test is used\n' >&2
        return 1
    fi

    if [[ -z "${LEVEL}" ]]; then
        printf -- '--level is required unless --setup, --validate, or --test is used\n' >&2
        return 1
    fi

    if [[ -z "${MESSAGE}" ]]; then
        printf -- '--message is required unless --setup, --validate, or --test is used\n' >&2
        return 1
    fi

    return 0
}

main() {
    if [[ "$#" -eq 0 ]]; then
        handle_no_arguments
        return $?
    fi

    parse_args "$@" || return 1

    if [[ "${DO_SETUP}" -eq 1 ]]; then
        run_setup
        return $?
    fi

    require_dependencies || return 1
    ensure_global_config_available || return 1
    load_global_config || return 1

    if [[ "${DO_TEST}" -eq 1 && -z "${CALLER}" ]]; then
        CALLER="manual-test"
    fi

    load_app_config || return 1

    if [[ "${DO_VALIDATE}" -eq 1 ]]; then
        validate_effective_config
        return $?
    fi

    if [[ "${DO_TEST}" -eq 1 ]]; then
        if [[ "${AUTO_SETUP_RAN}" -eq 1 && "${SETUP_SENT_TEST}" -eq 1 ]]; then
            return 0
        fi
        send_explicit_test_message
        return $?
    fi

    send_message "${LEVEL}" "${MESSAGE}"
    return $?
}

main "$@"
