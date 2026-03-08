#!/bin/bash
# Unit tests for server/otk/revocation_ledger.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../logging.sh"

# Override ledger paths to use a temp directory for testing
TEST_TMPDIR="$(mktemp -d)"
export OTK_LEDGER_DIR="${TEST_TMPDIR}/ledger"
export OTK_LEDGER_FILE="${OTK_LEDGER_DIR}/revocation.ledger"
export OTK_LEDGER_LOCK="${OTK_LEDGER_DIR}/.ledger.lock"
export OTK_LEDGER_PRUNE_DAYS=7
export OTK_LEDGER_MAX_ENTRIES=100000

source "${SCRIPT_DIR}/../../otk_config.sh"

# Disable -e so the test harness doesn't exit on expected failures.
set +e
source "${SCRIPT_DIR}/../../../server/otk/revocation_ledger.sh" 2>/dev/null || true
set +eo pipefail

_reset_ledger() {
    rm -rf "${OTK_LEDGER_DIR}"
    mkdir -p "${OTK_LEDGER_DIR}"
}

# ── init_ledger ─────────────────────────────────────────────────────────────

describe "init_ledger"

it "creates ledger directory"
_reset_ledger
rm -rf "${OTK_LEDGER_DIR}"
init_ledger 2>/dev/null
[[ -d "${OTK_LEDGER_DIR}" ]]; assert_zero $?

it "creates ledger file"
_reset_ledger
rm -f "${OTK_LEDGER_FILE}"
init_ledger 2>/dev/null
assert_file_exists "${OTK_LEDGER_FILE}"

it "ledger file starts empty"
_reset_ledger
rm -f "${OTK_LEDGER_FILE}"
init_ledger 2>/dev/null
count="$(wc -l < "${OTK_LEDGER_FILE}")"
assert_eq "0" "${count}"

it "is idempotent (calling twice is safe)"
_reset_ledger
init_ledger 2>/dev/null
init_ledger 2>/dev/null; assert_zero $?

# ── ledger_add ──────────────────────────────────────────────────────────────

describe "ledger_add"

it "adds a session ID to the ledger"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "abc123def456" 2>/dev/null
grep -q "abc123def456" "${OTK_LEDGER_FILE}"; assert_zero $?

it "adds timestamp with the entry"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "test_session_001" 2>/dev/null
line="$(cat "${OTK_LEDGER_FILE}")"
ts="${line%% *}"
[[ "${ts}" =~ ^[0-9]+$ ]]; assert_zero $?

it "supports multiple entries"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "session_a" 2>/dev/null
ledger_add "session_b" 2>/dev/null
ledger_add "session_c" 2>/dev/null
local count
count="$(wc -l < "${OTK_LEDGER_FILE}")"
assert_eq "3" "${count}"

it "rejects empty session ID"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "" 2>/dev/null; assert_nonzero $?

# ── ledger_check ────────────────────────────────────────────────────────────

describe "ledger_check"

it "returns 0 (revoked) for an added session"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "revoked_session" 2>/dev/null
ledger_check "revoked_session" 2>/dev/null; assert_zero $?

it "returns 1 (not revoked) for an unknown session"
_reset_ledger
init_ledger 2>/dev/null
ledger_check "never_seen" 2>/dev/null; assert_nonzero $?

it "returns 1 for empty ledger"
_reset_ledger
init_ledger 2>/dev/null
ledger_check "anything" 2>/dev/null; assert_nonzero $?

it "distinguishes between similar session IDs"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "abc123" 2>/dev/null
ledger_check "abc123" 2>/dev/null; assert_zero $?
ledger_check "abc124" 2>/dev/null; assert_nonzero $?

it "rejects empty session ID on check"
_reset_ledger
init_ledger 2>/dev/null
ledger_check "" 2>/dev/null; assert_nonzero $?

# ── ledger_prune ────────────────────────────────────────────────────────────

describe "ledger_prune"

it "removes old entries"
_reset_ledger
init_ledger 2>/dev/null
# Add an entry with an old timestamp (30 days ago)
old_ts=$(( $(date +%s) - 30 * 86400 ))
echo "${old_ts} old_session" >> "${OTK_LEDGER_FILE}"
# Add a recent entry
ledger_add "recent_session" 2>/dev/null
ledger_prune 2>/dev/null
# Old entry should be gone
grep -q "old_session" "${OTK_LEDGER_FILE}" 2>/dev/null; assert_nonzero $?

it "keeps recent entries"
_reset_ledger
init_ledger 2>/dev/null
old_ts=$(( $(date +%s) - 30 * 86400 ))
echo "${old_ts} old_session" >> "${OTK_LEDGER_FILE}"
ledger_add "recent_session" 2>/dev/null
ledger_prune 2>/dev/null
grep -q "recent_session" "${OTK_LEDGER_FILE}" 2>/dev/null; assert_zero $?

it "handles empty ledger"
_reset_ledger
init_ledger 2>/dev/null
ledger_prune 2>/dev/null; assert_zero $?

it "handles all-expired ledger"
_reset_ledger
init_ledger 2>/dev/null
old_ts=$(( $(date +%s) - 30 * 86400 ))
echo "${old_ts} expired_1" >> "${OTK_LEDGER_FILE}"
echo "${old_ts} expired_2" >> "${OTK_LEDGER_FILE}"
ledger_prune 2>/dev/null
count="$(wc -l < "${OTK_LEDGER_FILE}")"
assert_eq "0" "${count}"

# ── Replay prevention scenario ──────────────────────────────────────────────

describe "Replay prevention scenario"

it "blocks replay of a previously used session"
_reset_ledger
init_ledger 2>/dev/null
# Simulate: session key used → added to ledger
ledger_add "session_xyz_used" 2>/dev/null
# Attacker tries to replay the same session key
if ledger_check "session_xyz_used" 2>/dev/null; then
    pass  # Correctly detected as revoked — replay blocked
else
    fail "Replay not detected"
fi

it "allows a brand new session through"
_reset_ledger
init_ledger 2>/dev/null
ledger_add "old_session" 2>/dev/null
if ledger_check "brand_new_session" 2>/dev/null; then
    fail "New session incorrectly flagged as revoked"
else
    pass  # Correctly allowed through
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "${TEST_TMPDIR}"

test_summary
