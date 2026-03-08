#!/bin/bash
# Unit tests for client/otk/session_key.sh — Layer 2 session key engine

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"
source "${SCRIPT_DIR}/../../otk_config.sh"

# Source session_key.sh for function definitions.
# Disable -e so the test harness doesn't exit on expected failures.
set +e
source "${SCRIPT_DIR}/../../../client/otk/session_key.sh" 2>/dev/null || true
set +eo pipefail

TEST_TMPDIR=""

_cleanup_test() {
    [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
}

# ── generate_nonce ──────────────────────────────────────────────────────────

describe "generate_nonce"

it "creates a nonce file in the output directory"
TEST_TMPDIR="$(mktemp -d)"
generate_nonce "${TEST_TMPDIR}" >/dev/null 2>/dev/null
assert_file_exists "${TEST_TMPDIR}/nonce"
_cleanup_test

it "nonce contains timestamp:random format"
TEST_TMPDIR="$(mktemp -d)"
nonce="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
[[ "${nonce}" == *":"* ]]; assert_zero $?
_cleanup_test

it "nonce timestamp is a number"
TEST_TMPDIR="$(mktemp -d)"
nonce="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
ts="${nonce%%:*}"
[[ "${ts}" =~ ^[0-9]+$ ]]; assert_zero $?
_cleanup_test

it "nonce random component is hex"
TEST_TMPDIR="$(mktemp -d)"
nonce="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
random="${nonce#*:}"
[[ "${random}" =~ ^[0-9a-f]+$ ]]; assert_zero $?
_cleanup_test

it "nonce random has expected length (32 bytes = 64 hex chars)"
TEST_TMPDIR="$(mktemp -d)"
nonce="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
random="${nonce#*:}"
assert_eq "64" "${#random}"
_cleanup_test

it "two nonces are different"
TEST_TMPDIR="$(mktemp -d)"
nonce1="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
nonce2="$(generate_nonce "${TEST_TMPDIR}" 2>/dev/null)"
assert_ne "${nonce1}" "${nonce2}"
_cleanup_test

# ── validate_nonce ──────────────────────────────────────────────────────────

describe "validate_nonce"

it "accepts a fresh nonce"
ts="$(date +%s)"
validate_nonce "${ts}:abcdef0123456789" 2>/dev/null; assert_zero $?

it "rejects an expired nonce"
old_ts="$(( $(date +%s) - 600 ))"
validate_nonce "${old_ts}:abcdef0123456789" 2>/dev/null; assert_nonzero $?

it "rejects a future nonce"
future_ts="$(( $(date +%s) + 600 ))"
validate_nonce "${future_ts}:abcdef0123456789" 2>/dev/null; assert_nonzero $?

it "rejects a nonce with no random component"
ts="$(date +%s)"
validate_nonce "${ts}" 2>/dev/null; assert_nonzero $?

it "rejects a nonce with non-numeric timestamp"
validate_nonce "notanumber:abcdef" 2>/dev/null; assert_nonzero $?

it "accepts a nonce just within the time window"
recent_ts="$(( $(date +%s) - OTK_NONCE_MAX_AGE + 10 ))"
validate_nonce "${recent_ts}:abcdef0123456789" 2>/dev/null; assert_zero $?

# ── generate_session_id ─────────────────────────────────────────────────────

describe "generate_session_id"

it "produces a hex hash"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA... test" > "${TEST_TMPDIR}/pub"
sid="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" 2>/dev/null)"
[[ "${sid}" =~ ^[0-9a-f]+$ ]]; assert_zero $?
_cleanup_test

it "produces different IDs for different nonces"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA... test" > "${TEST_TMPDIR}/pub"
sid1="$(generate_session_id "11111:aaa" "${TEST_TMPDIR}/pub" 2>/dev/null)"
sid2="$(generate_session_id "22222:bbb" "${TEST_TMPDIR}/pub" 2>/dev/null)"
assert_ne "${sid1}" "${sid2}"
_cleanup_test

it "produces different IDs for different keys"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA... key1" > "${TEST_TMPDIR}/pub1"
echo "ssh-ed25519 BBBB... key2" > "${TEST_TMPDIR}/pub2"
sid1="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub1" 2>/dev/null)"
sid2="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub2" 2>/dev/null)"
assert_ne "${sid1}" "${sid2}"
_cleanup_test

it "produces same ID for same inputs (deterministic)"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA... test" > "${TEST_TMPDIR}/pub"
sid1="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" 2>/dev/null)"
sid2="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" 2>/dev/null)"
assert_eq "${sid1}" "${sid2}"
_cleanup_test

it "handles optional PQ pub key argument"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA..." > "${TEST_TMPDIR}/pub"
echo "ssh-mldsa-87 BBBB..." > "${TEST_TMPDIR}/pq_pub"
sid="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" "${TEST_TMPDIR}/pq_pub" 2>/dev/null)"
[[ -n "${sid}" ]]; assert_zero $?
_cleanup_test

it "ID changes when PQ key is added"
TEST_TMPDIR="$(mktemp -d)"
echo "ssh-ed25519 AAAA..." > "${TEST_TMPDIR}/pub"
echo "ssh-mldsa-87 BBBB..." > "${TEST_TMPDIR}/pq_pub"
sid_without="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" 2>/dev/null)"
sid_with="$(generate_session_id "12345:abc" "${TEST_TMPDIR}/pub" "${TEST_TMPDIR}/pq_pub" 2>/dev/null)"
assert_ne "${sid_without}" "${sid_with}"
_cleanup_test

test_summary
