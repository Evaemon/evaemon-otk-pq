#!/bin/bash
# Unit tests for shared/logging.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Capture stderr from a command into a variable
_capture_stderr() {
    "$@" 2>&1 >/dev/null
}

# Source logging fresh with a custom LOG_LEVEL each time
_load_logging() {
    local level="${1:-1}"
    LOG_LEVEL="$level"
    LOG_FILE=""
    source "${SCRIPT_DIR}/../../logging.sh"
}

# ── log_info / log_warn / log_error / log_debug ───────────────────────────────

describe "log levels — output filtering"

_load_logging 1   # INFO

it "log_info emits output at INFO level"
out="$(_capture_stderr log_info "hello")"
assert_contains "hello" "$out"

it "log_debug is suppressed at INFO level"
out="$(_capture_stderr log_debug "debug msg")"
[[ -z "$out" ]] && pass || fail "expected no output for DEBUG at INFO level"

it "log_warn emits output at INFO level"
out="$(_capture_stderr log_warn "watch out")"
assert_contains "watch out" "$out"

it "log_error emits output at INFO level"
out="$(_capture_stderr log_error "something broke")"
assert_contains "something broke" "$out"

_load_logging 0   # DEBUG

it "log_debug emits output at DEBUG level"
out="$(_capture_stderr log_debug "verbose details")"
assert_contains "verbose details" "$out"

_load_logging 3   # ERROR only

it "log_info is suppressed at ERROR level"
out="$(_capture_stderr log_info "info msg")"
[[ -z "$out" ]] && pass || fail "expected no output for INFO at ERROR level"

it "log_warn is suppressed at ERROR level"
out="$(_capture_stderr log_warn "warn msg")"
[[ -z "$out" ]] && pass || fail "expected no output for WARN at ERROR level"

it "log_error emits output at ERROR level"
out="$(_capture_stderr log_error "error msg")"
assert_contains "error msg" "$out"

# ── Level labels ──────────────────────────────────────────────────────────────

describe "log level labels in output"

_load_logging 0   # DEBUG (show everything)

it "log_info output contains INFO label"
out="$(_capture_stderr log_info "x")"
assert_contains "INFO" "$out"

it "log_warn output contains WARN label"
out="$(_capture_stderr log_warn "x")"
assert_contains "WARN" "$out"

it "log_error output contains ERROR label"
out="$(_capture_stderr log_error "x")"
assert_contains "ERROR" "$out"

it "log_debug output contains DEBUG label"
out="$(_capture_stderr log_debug "x")"
assert_contains "DEBUG" "$out"

# ── log_section ───────────────────────────────────────────────────────────────

describe "log_section"

_load_logging 1

it "log_section emits the section title"
out="$(_capture_stderr log_section "My Section")"
assert_contains "My Section" "$out"

it "log_section includes a separator line"
out="$(_capture_stderr log_section "Separator Test")"
# Should contain at least 5 dashes or box-drawing chars
echo "$out" | grep -qE '[-─]{5,}' && pass || fail "no separator found in log_section output"

# ── log_file output ───────────────────────────────────────────────────────────

describe "file logging"

_tmp_log="$(mktemp)"

it "messages are written to LOG_FILE when set"
LOG_FILE="${_tmp_log}"
source "${SCRIPT_DIR}/../../logging.sh"
log_info "file logging test" 2>/dev/null
assert_file_exists "${_tmp_log}"

it "LOG_FILE contains the message"
content="$(cat "${_tmp_log}")"
assert_contains "file logging test" "$content"

it "LOG_FILE entries do not contain ANSI escape codes"
content="$(cat "${_tmp_log}")"
# ANSI codes start with ESC (\x1b / \033)
if echo "$content" | grep -qP '\x1b\['; then
    fail "ANSI codes found in plain log file"
else
    pass
fi

rm -f "${_tmp_log}"
LOG_FILE=""

# ── log_fatal ─────────────────────────────────────────────────────────────────

describe "log_fatal"

_load_logging 1

it "log_fatal exits with code 1"
(
    source "${SCRIPT_DIR}/../../logging.sh"
    log_fatal "fatal error" 2>/dev/null
)
assert_nonzero $?

it "log_fatal message appears in output"
out="$( (source "${SCRIPT_DIR}/../../logging.sh"; log_fatal "boom") 2>&1 || true )"
assert_contains "boom" "$out"

# ── log_success (added in Phase 1) ───────────────────────────────────────────

describe "log_success"

_load_logging 1   # INFO

it "log_success emits output at INFO level"
out="$(_capture_stderr log_success "all good")"
assert_contains "all good" "$out"

it "log_success output contains OK label"
out="$(_capture_stderr log_success "done")"
assert_contains "OK" "$out"

it "log_success is suppressed at ERROR level"
_load_logging 3
out="$(_capture_stderr log_success "hidden")"
[[ -z "$out" ]] && pass || fail "expected no output for log_success at ERROR level"

it "log_success does not exit the script"
(
    source "${SCRIPT_DIR}/../../logging.sh"
    log_success "non-fatal" 2>/dev/null
    echo "still running"
) | grep -q "still running" && pass || fail "script exited after log_success"

# ── log_cmd ───────────────────────────────────────────────────────────────────

describe "log_cmd"

_load_logging 1

it "log_cmd returns 0 for a successful command"
log_cmd "true test" true 2>/dev/null
assert_zero $?

it "log_cmd returns non-zero for a failing command"
log_cmd "false test" false 2>/dev/null
assert_nonzero $?

it "log_cmd does not abort the calling script on failure"
(
    source "${SCRIPT_DIR}/../../logging.sh"
    log_cmd "failing" false 2>/dev/null
    echo "still running"
) | grep -q "still running" && pass || fail "script aborted after log_cmd failure"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
