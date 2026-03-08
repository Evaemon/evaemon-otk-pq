#!/bin/bash
# Unit tests for key age checking (check_key_age) added to key_rotation.sh
#
# Tests the 90-day rotation policy enforcement without requiring OQS or SSH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
mkdir -p "${WORK_SSH}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Source key_rotation.sh for its helper functions
SSH_DIR="${WORK_SSH}"
source "${PROJECT_ROOT}/client/key_rotation.sh" 2>/dev/null
set +eo pipefail
SSH_DIR="${WORK_SSH}"

# ── check_key_age ────────────────────────────────────────────────────────────

describe "check_key_age — rotation policy enforcement"

it "returns 0 (overdue) for a key older than 90 days"
_KEY="${WORK_SSH}/id_old_key"
printf 'FAKE_KEY\n' > "${_KEY}"
# Set mtime to 100 days ago
touch -d "100 days ago" "${_KEY}" 2>/dev/null || touch -t "$(date -d '100 days ago' +%Y%m%d%H%M.%S)" "${_KEY}" 2>/dev/null
rc=0
(KEY_MAX_AGE_DAYS=90 check_key_age "${_KEY}" 2>/dev/null) || rc=$?
assert_zero $rc

it "returns 1 (within policy) for a key younger than 90 days"
_KEY2="${WORK_SSH}/id_fresh_key"
printf 'FAKE_KEY\n' > "${_KEY2}"
# File just created, so it's 0 days old
rc=0
(KEY_MAX_AGE_DAYS=90 check_key_age "${_KEY2}" 2>/dev/null) || rc=$?
assert_nonzero $rc

it "returns 0 (overdue) for a key exactly at the threshold"
_KEY3="${WORK_SSH}/id_threshold_key"
printf 'FAKE_KEY\n' > "${_KEY3}"
touch -d "90 days ago" "${_KEY3}" 2>/dev/null || touch -t "$(date -d '90 days ago' +%Y%m%d%H%M.%S)" "${_KEY3}" 2>/dev/null
rc=0
(KEY_MAX_AGE_DAYS=90 check_key_age "${_KEY3}" 2>/dev/null) || rc=$?
assert_zero $rc

it "returns 1 for a nonexistent key file"
rc=0
(check_key_age "${WORK_SSH}/nonexistent" 2>/dev/null) || rc=$?
assert_nonzero $rc

it "respects custom KEY_MAX_AGE_DAYS (30 days)"
_KEY4="${WORK_SSH}/id_custom_age"
printf 'FAKE_KEY\n' > "${_KEY4}"
touch -d "31 days ago" "${_KEY4}" 2>/dev/null || touch -t "$(date -d '31 days ago' +%Y%m%d%H%M.%S)" "${_KEY4}" 2>/dev/null
rc=0
(KEY_MAX_AGE_DAYS=30 check_key_age "${_KEY4}" 2>/dev/null) || rc=$?
assert_zero $rc

it "key within custom 30-day window passes"
_KEY5="${WORK_SSH}/id_custom_ok"
printf 'FAKE_KEY\n' > "${_KEY5}"
touch -d "10 days ago" "${_KEY5}" 2>/dev/null || touch -t "$(date -d '10 days ago' +%Y%m%d%H%M.%S)" "${_KEY5}" 2>/dev/null
rc=0
(KEY_MAX_AGE_DAYS=30 check_key_age "${_KEY5}" 2>/dev/null) || rc=$?
assert_nonzero $rc

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
