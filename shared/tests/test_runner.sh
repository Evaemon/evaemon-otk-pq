#!/bin/bash
# Minimal self-contained test harness for Evaemon.
#
# Usage (source this file, then call the public API):
#   source shared/tests/test_runner.sh
#   describe "my suite"
#   it "does something" && { assert_eq "a" "a"; }
#   test_summary
#
# Exit code: 0 if all tests pass, 1 if any fail.

# ── Counters ──────────────────────────────────────────────────────────────────
_TR_TOTAL=0
_TR_PASS=0
_TR_FAIL=0
_TR_SUITE=""
_TR_TEST=""

# ── Colour ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    _C_GREEN='\033[0;32m'
    _C_RED='\033[0;31m'
    _C_CYAN='\033[0;36m'
    _C_YELLOW='\033[0;33m'
    _C_RESET='\033[0m'
else
    _C_GREEN='' _C_RED='' _C_CYAN='' _C_YELLOW='' _C_RESET=''
fi

# ── Public API ────────────────────────────────────────────────────────────────

# describe SUITE_NAME — start a new test suite block
describe() {
    _TR_SUITE="$1"
    echo -e "\n${_C_CYAN}== ${_TR_SUITE} ==${_C_RESET}"
}

# it TEST_NAME — record the name of the next test
it() {
    _TR_TEST="$1"
    (( _TR_TOTAL++ )) || true
}

# pass — mark the current test as passed
pass() {
    (( _TR_PASS++ )) || true
    echo -e "  ${_C_GREEN}PASS${_C_RESET}  ${_TR_TEST}"
}

# fail [REASON] — mark the current test as failed
fail() {
    (( _TR_FAIL++ )) || true
    local reason="${1:-}"
    if [[ -n "$reason" ]]; then
        echo -e "  ${_C_RED}FAIL${_C_RESET}  ${_TR_TEST}  (${reason})"
    else
        echo -e "  ${_C_RED}FAIL${_C_RESET}  ${_TR_TEST}"
    fi
}

# skip [REASON] — mark the current test as skipped (counts as pass)
skip() {
    (( _TR_PASS++ )) || true
    echo -e "  ${_C_YELLOW}SKIP${_C_RESET}  ${_TR_TEST}  (${1:-skipped})"
}

# ── Assertion helpers ─────────────────────────────────────────────────────────

# assert_eq EXPECTED ACTUAL
assert_eq() {
    local expected="$1" actual="$2"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "expected '${expected}', got '${actual}'"
    fi
}

# assert_ne UNEXPECTED ACTUAL
assert_ne() {
    local unexpected="$1" actual="$2"
    if [[ "$unexpected" != "$actual" ]]; then
        pass
    else
        fail "expected value to differ from '${unexpected}'"
    fi
}

# assert_zero EXIT_CODE — assert a command returned 0
assert_zero() {
    local rc="$1"
    if [[ "$rc" -eq 0 ]]; then
        pass
    else
        fail "expected exit 0, got ${rc}"
    fi
}

# assert_nonzero EXIT_CODE — assert a command returned non-zero
assert_nonzero() {
    local rc="$1"
    if [[ "$rc" -ne 0 ]]; then
        pass
    else
        fail "expected non-zero exit, got 0"
    fi
}

# assert_contains NEEDLE HAYSTACK
assert_contains() {
    local needle="$1" haystack="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass
    else
        fail "'${haystack}' does not contain '${needle}'"
    fi
}

# assert_file_exists PATH
assert_file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        pass
    else
        fail "file not found: ${path}"
    fi
}

# assert_file_perms EXPECTED_OCTAL PATH
assert_file_perms() {
    local expected="$1" path="$2"
    local actual
    actual="$(stat -c "%a" "$path" 2>/dev/null || echo "missing")"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "perms for ${path}: expected ${expected}, got ${actual}"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

# test_summary — print results and exit with 0 (all pass) or 1 (any fail)
test_summary() {
    echo
    echo -e "${_C_CYAN}Results: ${_TR_TOTAL} tests, " \
            "${_C_GREEN}${_TR_PASS} passed${_C_RESET}, " \
            "${_C_RED}${_TR_FAIL} failed${_C_RESET}"
    if [[ $_TR_FAIL -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}
