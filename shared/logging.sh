#!/bin/bash

# Centralized logging module for Evaemon
# Provides structured logging with levels, timestamps, and optional file output.
#
# Usage:
#   source shared/logging.sh
#   log_info "Starting process..."
#   log_warn "Something looks off"
#   log_error "Fatal failure" && exit 1

# ── Configuration ────────────────────────────────────────────────────────────

# Log level constants (lower number = more verbose).
# Guard against re-sourcing: readonly fails if the variable already exists.
if ! [[ -v LOG_LEVEL_DEBUG ]]; then
    readonly LOG_LEVEL_DEBUG=0
    readonly LOG_LEVEL_INFO=1
    readonly LOG_LEVEL_WARN=2
    readonly LOG_LEVEL_ERROR=3
fi

# Active log level — override before sourcing or export from environment.
# Defaults to INFO.
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Optional log file. Leave empty to disable file logging.
# Scripts that want file logging should set this before sourcing:
#   LOG_FILE="/path/to/file.log"  source shared/logging.sh
LOG_FILE="${LOG_FILE:-}"

# Whether to emit ANSI colour codes (auto-detected; set to 0 to disable).
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    _LOG_COLOR=1
else
    _LOG_COLOR=0
fi

# ── Colour codes ─────────────────────────────────────────────────────────────
# Use $'...' ANSI-C quoting so the ESC byte is stored literally in each
# variable.  This lets _log_write use printf '%s\n' instead of echo -e,
# which means user-controlled message text can never inject escape sequences
# (terminal injection / log-injection defence).

_CLR_RESET=$'\033[0m'
_CLR_GREY=$'\033[0;90m'
_CLR_WHITE=$'\033[0;37m'
_CLR_GREEN=$'\033[0;32m'
_CLR_CYAN=$'\033[0;36m'
_CLR_YELLOW=$'\033[0;33m'
_CLR_RED=$'\033[0;31m'
_CLR_BOLD_RED=$'\033[1;31m'

# ── Internal helpers ─────────────────────────────────────────────────────────

_log_timestamp() {
    date "+%Y-%m-%d %H:%M:%S.%3N"
}

_log_write() {
    local level_name="$1"
    local color="$2"
    local message="$3"
    local timestamp
    timestamp="$(_log_timestamp)"
    local formatted

    if [[ "$_LOG_COLOR" -eq 1 ]]; then
        formatted="${_CLR_GREY}${timestamp}${_CLR_RESET} ${color}[${level_name}]${_CLR_RESET} ${message}"
    else
        formatted="${timestamp} [${level_name}] ${message}"
    fi

    # Always write to stderr so it doesn't pollute stdout pipelines.
    # printf '%s\n' is used instead of echo -e so that user-controlled message
    # text cannot inject terminal escape sequences (terminal/log injection).
    # Color codes work because the _CLR_* variables now hold real ESC bytes
    # (defined with $'...' ANSI-C quoting above).
    printf '%s\n' "$formatted" >&2

    # Optionally mirror to log file (plain, no colour codes)
    if [[ -n "$LOG_FILE" ]]; then
        local dir
        dir="$(dirname "$LOG_FILE")"
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
        fi
        echo "${timestamp} [${level_name}] ${message}" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ── Public API ───────────────────────────────────────────────────────────────

# log_debug MESSAGE  — verbose diagnostic output
log_debug() {
    [[ "$LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ]] || return 0
    _log_write "DEBUG" "$_CLR_CYAN" "$*"
}

# log_info MESSAGE  — normal informational output
log_info() {
    [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]] || return 0
    _log_write "INFO " "$_CLR_WHITE" "$*"
}

# log_success MESSAGE  — highlight a successful outcome
log_success() {
    [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]] || return 0
    _log_write "OK   " "$_CLR_GREEN" "$*"
}

# log_warn MESSAGE  — something unexpected but non-fatal
log_warn() {
    [[ "$LOG_LEVEL" -le "$LOG_LEVEL_WARN" ]] || return 0
    _log_write "WARN " "$_CLR_YELLOW" "$*"
}

# log_error MESSAGE  — an error that will (usually) cause the script to exit
log_error() {
    [[ "$LOG_LEVEL" -le "$LOG_LEVEL_ERROR" ]] || return 0
    _log_write "ERROR" "$_CLR_BOLD_RED" "$*"
}

# log_section TITLE  — print a visible section divider
log_section() {
    local title="$1"
    local line="──────────────────────────────────────────"
    if [[ "$_LOG_COLOR" -eq 1 ]]; then
        printf '\n%s\n' "${_CLR_CYAN}${line}${_CLR_RESET}" >&2
        printf '%s\n' "${_CLR_CYAN}  ${title}${_CLR_RESET}" >&2
        printf '%s\n\n' "${_CLR_CYAN}${line}${_CLR_RESET}" >&2
    else
        printf '\n%s\n  %s\n%s\n\n' "${line}" "${title}" "${line}" >&2
    fi
    if [[ -n "$LOG_FILE" ]]; then
        {
            echo ""
            echo "${line}"
            echo "  ${title}"
            echo "${line}"
            echo ""
        } >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# log_fatal MESSAGE  — log an error then exit with code 1
log_fatal() {
    log_error "$*"
    exit 1
}

# log_cmd DESCRIPTION COMMAND [ARGS...]
# Run a command, log its outcome, and return its exit code.
log_cmd() {
    local description="$1"
    shift
    log_debug "Running: $*"
    if "$@"; then
        log_debug "${description}: OK"
        return 0
    else
        local rc=$?
        log_error "${description} failed (exit ${rc})"
        return $rc
    fi
}
