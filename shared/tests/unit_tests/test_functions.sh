#!/bin/bash
# Unit tests for shared/functions.sh
# Covers: retry_with_backoff (added in Phase 1) and log_success (logging.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"
source "${PROJECT_ROOT}/shared/config.sh"
source "${PROJECT_ROOT}/shared/logging.sh"
source "${PROJECT_ROOT}/shared/validation.sh"
source "${PROJECT_ROOT}/shared/functions.sh"

_capture_err() { "$@" 2>&1 >/dev/null; }

# ── retry_with_backoff — success paths ───────────────────────────────────────

describe "retry_with_backoff — success paths"

it "returns 0 when the command succeeds on the first attempt"
retry_with_backoff 3 0 true 2>/dev/null
assert_zero $?

it "returns 0 when a command succeeds on the second attempt"
_rb_count=0
_rb_fail_once() { (( _rb_count++ )) || true; [[ "$_rb_count" -ge 2 ]]; }
_rb_count=0
retry_with_backoff 3 0 _rb_fail_once 2>/dev/null
assert_zero $?

it "returns 0 after exactly two failures then success"
_rb_count2=0
_rb_fail_twice() { (( _rb_count2++ )) || true; [[ "$_rb_count2" -ge 3 ]]; }
_rb_count2=0
retry_with_backoff 3 0 _rb_fail_twice 2>/dev/null
assert_zero $?

# ── retry_with_backoff — failure paths ───────────────────────────────────────

describe "retry_with_backoff — failure paths"

it "returns non-zero when every attempt fails"
retry_with_backoff 3 0 false 2>/dev/null
assert_nonzero $?

it "attempts exactly MAX_ATTEMPTS times before giving up"
_rb_call_count=0
_rb_always_fail() { (( _rb_call_count++ )) || true; return 1; }
_rb_call_count=0
retry_with_backoff 4 0 _rb_always_fail 2>/dev/null || true
assert_eq "4" "$_rb_call_count"

it "does not retry when max_attempts is 1"
_rb_count_once=0
_rb_one_shot() { (( _rb_count_once++ )) || true; return 1; }
_rb_count_once=0
retry_with_backoff 1 0 _rb_one_shot 2>/dev/null || true
assert_eq "1" "$_rb_count_once"

it "stops retrying as soon as a success occurs"
_rb_stop=0
_rb_stop_early() { (( _rb_stop++ )) || true; [[ "$_rb_stop" -ge 2 ]]; }
_rb_stop=0
retry_with_backoff 5 0 _rb_stop_early 2>/dev/null
assert_eq "2" "$_rb_stop"

it "emits a warning message on each failed attempt"
_rb_out="$(retry_with_backoff 2 0 false 2>&1 || true)"
assert_contains "failed" "$_rb_out"

it "emits an error after all attempts are exhausted"
_rb_out2="$(retry_with_backoff 1 0 false 2>&1 || true)"
assert_contains "failed" "$_rb_out2"

# ── log_success (added in Phase 1) ───────────────────────────────────────────

describe "log_success"

it "emits output at INFO level"
LOG_LEVEL=1; source "${PROJECT_ROOT}/shared/logging.sh"
out="$(_capture_err log_success "operation done")"
assert_contains "operation done" "$out"

it "output contains the OK label"
out="$(_capture_err log_success "ok test")"
assert_contains "OK" "$out"

it "is suppressed at ERROR level"
LOG_LEVEL=3; source "${PROJECT_ROOT}/shared/logging.sh"
out="$(_capture_err log_success "should be hidden")"
[[ -z "$out" ]] && pass || fail "expected no output for log_success at ERROR level"

it "is emitted at DEBUG level"
LOG_LEVEL=0; source "${PROJECT_ROOT}/shared/logging.sh"
out="$(_capture_err log_success "debug success")"
assert_contains "debug success" "$out"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
