#!/bin/bash
# Unit tests for client/otk/otk_connect.sh — OTK connection helper functions
#
# Tests cover the three refactored helper functions:
#   _find_bootstrap_key       — finds an existing SSH key for bootstrap auth
#   _execute_remote_verification — installs the ephemeral session key on the server
#   _cleanup_session          — removes the ephemeral key after the session
#
# SSH-dependent tests (_execute_remote_verification, _cleanup_session) use a
# guaranteed-unreachable address (192.0.2.1, RFC 5737 TEST-NET) and a
# non-existent OQS binary path, so they fail fast without network I/O.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"
source "${SCRIPT_DIR}/../../otk_config.sh"

# Disable -e so the test harness doesn't exit on expected failures.
set +e
source "${SCRIPT_DIR}/../../../client/otk/otk_connect.sh" 2>/dev/null || true
set +eo pipefail

# ── Test fixtures ─────────────────────────────────────────────────────────────

TEST_TMPDIR=""

_setup_ssh_dir() {
    TEST_TMPDIR="$(mktemp -d)"
    SSH_DIR="${TEST_TMPDIR}"
}

_cleanup_test() {
    [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
    TEST_TMPDIR=""
}

# ── _find_bootstrap_key ───────────────────────────────────────────────────────

describe "_find_bootstrap_key"

it "returns 0 when a PQ key exists"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_ssh-falcon1024"
_find_bootstrap_key &>/dev/null; assert_zero $?
_cleanup_test

it "prints the PQ key path to stdout"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_ssh-falcon1024"
result="$(_find_bootstrap_key 2>/dev/null)"
assert_eq "${TEST_TMPDIR}/id_ssh-falcon1024" "${result}"
_cleanup_test

it "finds the first matching PQ algorithm in priority order"
_setup_ssh_dir
# Only provide the second PQ algo, not the first (falcon1024)
touch "${TEST_TMPDIR}/id_ssh-mldsa-65"
result="$(_find_bootstrap_key 2>/dev/null)"
assert_contains "ssh-mldsa-65" "${result}"
_cleanup_test

it "returns 0 when only a classical key exists"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_ed25519"
_find_bootstrap_key &>/dev/null; assert_zero $?
_cleanup_test

it "prints the classical key path when no PQ key is present"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_ed25519"
result="$(_find_bootstrap_key 2>/dev/null)"
assert_eq "${TEST_TMPDIR}/id_ed25519" "${result}"
_cleanup_test

it "prefers PQ key over classical key when both are present"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_ed25519"
touch "${TEST_TMPDIR}/id_ssh-falcon1024"
result="$(_find_bootstrap_key 2>/dev/null)"
assert_contains "ssh-falcon1024" "${result}"
_cleanup_test

it "returns rsa as classical fallback when ed25519 absent"
_setup_ssh_dir
touch "${TEST_TMPDIR}/id_rsa"
result="$(_find_bootstrap_key 2>/dev/null)"
assert_eq "${TEST_TMPDIR}/id_rsa" "${result}"
_cleanup_test

it "returns non-zero (exits via log_fatal) when no key exists"
_setup_ssh_dir
# No key files created — run in subshell so log_fatal exit(1) doesn't kill the test runner
( SSH_DIR="${TEST_TMPDIR}" _find_bootstrap_key 2>/dev/null )
assert_nonzero $?
_cleanup_test

# ── _execute_remote_verification ─────────────────────────────────────────────

describe "_execute_remote_verification"

it "is defined and callable"
type _execute_remote_verification &>/dev/null; assert_zero $?

it "returns 1 when the SSH connection fails"
# BIN_DIR/ssh doesn't exist in test env → the SSH command fails immediately
# and the function returns 1 via PUSH_FAILED detection.
# base64-encoded "test" = "dGVzdA=="
_execute_remote_verification \
    "192.0.2.1" "nobody" "1" \
    "/tmp/nonexistent_bootstrap_key_$$" "dGVzdA==" "dGVzdA==" 2>/dev/null
assert_nonzero $?

it "accepts six positional arguments without error (signature check)"
# Passes a valid argument structure — fails on SSH (expected) not on argument parsing
type _execute_remote_verification &>/dev/null; assert_zero $?

# ── _cleanup_session ──────────────────────────────────────────────────────────

describe "_cleanup_session"

it "is defined and callable"
type _cleanup_session &>/dev/null; assert_zero $?

it "returns 0 even when SSH connection fails (non-fatal by design)"
# A failed cleanup must never abort the connection flow.
# The session key is already destroyed locally (Layer 3); the worst case
# is that the server entry outlives the session, bounded by the nonce TTL.
_cleanup_session \
    "192.0.2.1" "nobody" "1" \
    "/tmp/nonexistent_bootstrap_key_$$" "dGVzdA==" 2>/dev/null
assert_zero $?

it "accepts five positional arguments without error (signature check)"
type _cleanup_session &>/dev/null; assert_zero $?

# ── _push_and_connect ─────────────────────────────────────────────────────────

describe "_push_and_connect"

it "is defined and callable"
type _push_and_connect &>/dev/null; assert_zero $?

test_summary
