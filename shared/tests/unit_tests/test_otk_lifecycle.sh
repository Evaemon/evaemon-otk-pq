#!/bin/bash
# Unit tests for client/otk/otk_lifecycle.sh — Layer 3 destruction & lifecycle

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"
source "${SCRIPT_DIR}/../../otk_config.sh"

# Source the lifecycle module (functions only, not main)
# Temporarily disable -e so sourcing scripts with set -eo pipefail doesn't
# cause the test harness to exit on expected non-zero return codes.
set +e
source "${SCRIPT_DIR}/../../../client/otk/otk_lifecycle.sh" 2>/dev/null || true
set +eo pipefail

# ── Test fixtures ────────────────────────────────────────────────────────────

TEST_TMPDIR=""

_setup_test_bundle() {
    TEST_TMPDIR="$(mktemp -d)"
    local bundle="${TEST_TMPDIR}/test_bundle"
    mkdir -p "${bundle}"

    # Create mock session key files
    echo "PRIVATE_KEY_DATA_MOCK_12345" > "${bundle}/session_key"
    echo "PUBLIC_KEY_DATA_MOCK_12345" > "${bundle}/session_key.pub"
    echo "PQ_PRIVATE_KEY_DATA_MOCK" > "${bundle}/session_pq_key"
    echo "PQ_PUBLIC_KEY_DATA_MOCK" > "${bundle}/session_pq_key.pub"
    echo "SIGNATURE_DATA_MOCK" > "${bundle}/master_signature"
    echo "1234567890:abcdef0123456789" > "${bundle}/nonce"
    echo "abc123def456session_id_hash" > "${bundle}/session_id"

    chmod 600 "${bundle}/session_key" "${bundle}/session_pq_key"

    echo "${bundle}"
}

_cleanup_test() {
    [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
}

# ── _secure_delete ──────────────────────────────────────────────────────────

describe "_secure_delete"

it "deletes an existing file"
TEST_TMPDIR="$(mktemp -d)"
echo "secret data" > "${TEST_TMPDIR}/testfile"
_secure_delete "${TEST_TMPDIR}/testfile"
[[ ! -f "${TEST_TMPDIR}/testfile" ]]; assert_zero $?
_cleanup_test

it "handles non-existent file gracefully"
_secure_delete "/tmp/nonexistent_otk_test_file_$$" 2>/dev/null; assert_zero $?

it "deletes file with binary content"
TEST_TMPDIR="$(mktemp -d)"
dd if=/dev/urandom of="${TEST_TMPDIR}/binary_file" bs=256 count=1 2>/dev/null
_secure_delete "${TEST_TMPDIR}/binary_file"
[[ ! -f "${TEST_TMPDIR}/binary_file" ]]; assert_zero $?
_cleanup_test

# ── destroy_session ──────────────────────────────────────────────────────────

describe "destroy_session"

it "destroys all files in a session bundle"
bundle="$(_setup_test_bundle)"
destroy_session "${bundle}" 2>/dev/null
[[ ! -f "${bundle}/session_key" ]]; assert_zero $?
_cleanup_test

it "removes the bundle directory"
bundle="$(_setup_test_bundle)"
destroy_session "${bundle}" 2>/dev/null
[[ ! -d "${bundle}" ]]; assert_zero $?
_cleanup_test

it "handles already-destroyed bundle gracefully"
destroy_session "/tmp/nonexistent_bundle_$$" 2>/dev/null; assert_zero $?

it "destroys private keys first"
bundle="$(_setup_test_bundle)"
# After destroy, no private key files should remain
destroy_session "${bundle}" 2>/dev/null
priv_found=false
[[ -f "${bundle}/session_key" ]] && priv_found=true
[[ -f "${bundle}/session_pq_key" ]] && priv_found=true
[[ "${priv_found}" == "false" ]]; assert_zero $?
_cleanup_test

it "destroys export subdirectory if present"
bundle="$(_setup_test_bundle)"
mkdir -p "${bundle}/export"
echo "pubkey" > "${bundle}/export/session_key.pub"
echo "pubkey_pq" > "${bundle}/export/session_pq_key.pub"
destroy_session "${bundle}" 2>/dev/null
[[ ! -d "${bundle}/export" ]]; assert_zero $?
_cleanup_test

# ── verify_destruction ───────────────────────────────────────────────────────

describe "verify_destruction"

it "returns 0 when bundle directory is gone"
verify_destruction "/tmp/nonexistent_bundle_$$" 2>/dev/null; assert_zero $?

it "returns 0 after successful destroy_session"
bundle="$(_setup_test_bundle)"
destroy_session "${bundle}" 2>/dev/null
verify_destruction "${bundle}" 2>/dev/null; assert_zero $?
_cleanup_test

it "returns 1 when session key still exists"
bundle="$(_setup_test_bundle)"
# Delete everything except session_key
rm -f "${bundle}/session_key.pub" "${bundle}/session_pq_key" "${bundle}/session_pq_key.pub"
rm -f "${bundle}/master_signature" "${bundle}/nonce" "${bundle}/session_id"
verify_destruction "${bundle}" 2>/dev/null; assert_nonzero $?
_cleanup_test

it "returns 1 when multiple files remain"
bundle="$(_setup_test_bundle)"
# Don't destroy anything — all files remain
verify_destruction "${bundle}" 2>/dev/null; assert_nonzero $?
_cleanup_test

# ── mark_session_used / is_session_used ──────────────────────────────────────

describe "mark_session_used / is_session_used"

it "is_session_used returns 1 for unused session"
bundle="$(_setup_test_bundle)"
is_session_used "${bundle}" 2>/dev/null; assert_nonzero $?
_cleanup_test

it "mark_session_used creates .used marker"
bundle="$(_setup_test_bundle)"
mark_session_used "${bundle}" 2>/dev/null
[[ -f "${bundle}/.used" ]]; assert_zero $?
_cleanup_test

it "is_session_used returns 0 after marking"
bundle="$(_setup_test_bundle)"
mark_session_used "${bundle}" 2>/dev/null
is_session_used "${bundle}" 2>/dev/null; assert_zero $?
_cleanup_test

it "mark_session_used fails for nonexistent bundle"
mark_session_used "/tmp/nonexistent_$$" 2>/dev/null; assert_nonzero $?

# ── Full lifecycle ───────────────────────────────────────────────────────────

describe "Full lifecycle (mark → destroy → verify)"

it "complete lifecycle succeeds"
bundle="$(_setup_test_bundle)"
mark_session_used "${bundle}" 2>/dev/null
destroy_session "${bundle}" 2>/dev/null
verify_destruction "${bundle}" 2>/dev/null; assert_zero $?
_cleanup_test

test_summary
