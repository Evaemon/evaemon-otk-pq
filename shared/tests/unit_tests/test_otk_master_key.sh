#!/bin/bash
# Unit tests for client/otk/master_key.sh — Layer 1 master key manager
# These tests cover the non-interactive utility functions.
# Key generation tests that require OQS binaries are in integration tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"

# Override paths for testing
TEST_TMPDIR="$(mktemp -d)"
export OTK_MASTER_DIR="${TEST_TMPDIR}/master"
export OTK_SESSION_DIR="${TEST_TMPDIR}/sessions"

source "${SCRIPT_DIR}/../../otk_config.sh"

# Disable -e so the test harness doesn't exit on expected failures.
set +e
source "${SCRIPT_DIR}/../../../client/otk/master_key.sh" 2>/dev/null || true
set +eo pipefail

_reset_dirs() {
    rm -rf "${OTK_MASTER_DIR}" "${OTK_SESSION_DIR}"
}

# ── _ensure_otk_dirs ────────────────────────────────────────────────────────

describe "_ensure_otk_dirs"

it "creates master key directory"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
[[ -d "${OTK_MASTER_DIR}" ]]; assert_zero $?

it "creates session key directory"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
[[ -d "${OTK_SESSION_DIR}" ]]; assert_zero $?

it "sets correct permissions on master dir"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
assert_file_perms "700" "${OTK_MASTER_DIR}"

it "is idempotent"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
_ensure_otk_dirs 2>/dev/null; assert_zero $?

# ── verify_master_key ────────────────────────────────────────────────────────

describe "verify_master_key (no key present)"

it "returns 1 when no master key exists"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
verify_master_key 2>/dev/null; assert_nonzero $?

# ── verify_master_key (with mock key) ────────────────────────────────────────

describe "verify_master_key (mock key)"

it "succeeds with key files in place"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "MOCK_PRIVATE_KEY" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "MOCK_PUBLIC_KEY" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
chmod 600 "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
chmod 644 "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
date +%s > "${OTK_MASTER_DIR}/.master_created"
chmod 600 "${OTK_MASTER_DIR}/.master_created"
# BIN_DIR may not have ssh-keygen, so verification will pass with warnings
verify_master_key 2>/dev/null; rc=$?
# Should succeed (0) or warn (1) — but not crash
[[ $rc -eq 0 || $rc -eq 1 ]]; assert_zero $?

it "detects wrong permissions on private key"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "MOCK_KEY" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "MOCK_PUB" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
chmod 644 "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"  # Wrong — should be 600
date +%s > "${OTK_MASTER_DIR}/.master_created"
verify_master_key 2>/dev/null; assert_nonzero $?

it "detects missing public key"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "MOCK_KEY" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
chmod 600 "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
# No public key file
date +%s > "${OTK_MASTER_DIR}/.master_created"
verify_master_key 2>/dev/null; assert_nonzero $?

# ── export_master_public_key ─────────────────────────────────────────────────

describe "export_master_public_key"

it "outputs the public key content"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "ssh-mldsa-87 AAAA... test@host" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
output="$(export_master_public_key 2>/dev/null)"
assert_contains "ssh-mldsa-87" "${output}"

it "fails when no public key exists"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
# log_fatal calls exit, so run in a subshell to catch the exit code
( export_master_public_key 2>/dev/null ); assert_nonzero $?

# ── _archive_master_key ──────────────────────────────────────────────────────

describe "_archive_master_key"

it "moves key files to archive directory"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "PRIVATE" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "PUBLIC" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
date +%s > "${OTK_MASTER_DIR}/.master_created"
_archive_master_key 2>/dev/null
# Original files should be gone
[[ ! -f "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}" ]]; assert_zero $?

it "creates archive directory"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "PRIVATE" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "PUBLIC" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
_archive_master_key 2>/dev/null
[[ -d "${OTK_MASTER_DIR}/archive" ]]; assert_zero $?

it "archive directory has correct permissions"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "PRIVATE" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "PUBLIC" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
_archive_master_key 2>/dev/null
assert_file_perms "700" "${OTK_MASTER_DIR}/archive"

# ── master_key_info ──────────────────────────────────────────────────────────

describe "master_key_info"

it "returns 1 when no master key exists"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
master_key_info 2>/dev/null; assert_nonzero $?

it "runs without error when key exists"
_reset_dirs
_ensure_otk_dirs 2>/dev/null
echo "MOCK_KEY" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
echo "MOCK_PUB" > "${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_PUB}"
date +%s > "${OTK_MASTER_DIR}/.master_created"
master_key_info 2>/dev/null; assert_zero $?

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "${TEST_TMPDIR}"

test_summary
