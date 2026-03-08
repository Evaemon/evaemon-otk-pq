#!/bin/bash
# Integration tests for client/key_rotation.sh
#
# Tests the local helper functions (archive_old_key) directly and exercises
# the retry logic in verify_new_key using a mock SSH wrapper.  No real server
# or OQS binary is required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
mkdir -p "${WORK_SSH}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Source key_rotation.sh for its helper functions.
# The BASH_SOURCE guard prevents main() from running.
# key_rotation.sh has set -eo pipefail, so disable that after sourcing.
SSH_DIR="${WORK_SSH}"
source "${PROJECT_ROOT}/client/key_rotation.sh" 2>/dev/null
set +eo pipefail
SSH_DIR="${WORK_SSH}"     # re-assert after config.sh re-sourcing

# ── archive_old_key ───────────────────────────────────────────────────────────

describe "archive_old_key — private + public key pair"

_KF="${WORK_SSH}/id_ssh-falcon1024"
printf 'FAKE_PRIVATE\n' > "${_KF}"
printf 'FAKE_PUBLIC\n'  > "${_KF}.pub"
chmod 600 "${_KF}"
chmod 644 "${_KF}.pub"

it "renames the private key to a .retired_TIMESTAMP filename"
archive_old_key "${_KF}" 2>/dev/null
retired_priv="$(ls "${WORK_SSH}/id_ssh-falcon1024.retired_"* 2>/dev/null | head -1)"
[[ -n "$retired_priv" ]] && pass || fail "no .retired_* private key found in ${WORK_SSH}"

it "renames the public key to a .retired_TIMESTAMP filename"
retired_pub="$(ls "${WORK_SSH}/id_ssh-falcon1024.pub.retired_"* 2>/dev/null | head -1)"
[[ -n "$retired_pub" ]] && pass || fail "no .retired_* public key found in ${WORK_SSH}"

it "sets 400 permissions on the retired private key"
assert_file_perms "400" "${retired_priv}"

it "sets 400 permissions on the retired public key"
assert_file_perms "400" "${retired_pub}"

it "retired private key content matches original"
content="$(cat "$retired_priv" 2>/dev/null || echo "")"
assert_contains "FAKE_PRIVATE" "$content"

it "retired public key content matches original"
content="$(cat "$retired_pub" 2>/dev/null || echo "")"
assert_contains "FAKE_PUBLIC" "$content"

it "original private key no longer exists after archiving"
[[ ! -f "${_KF}" ]] && pass || fail "original private key still present after archive"

describe "archive_old_key — missing public key"

_KF2="${WORK_SSH}/id_ssh-dilithium3"
printf 'PRIV_ONLY\n' > "${_KF2}"
chmod 600 "${_KF2}"

it "archives private key even when .pub file is absent"
archive_old_key "${_KF2}" 2>/dev/null
retired2="$(ls "${WORK_SSH}/id_ssh-dilithium3.retired_"* 2>/dev/null | head -1)"
[[ -n "$retired2" ]] && pass || fail "private key not archived when .pub was absent"

it "does not error when the .pub file does not exist"
rc=0
(archive_old_key "${_KF2}" 2>/dev/null) || rc=$?
assert_zero $rc

describe "archive_old_key — non-existent key"

it "exits 0 gracefully when neither file exists"
rc=0
(archive_old_key "${WORK_SSH}/id_ssh-nonexistent" 2>/dev/null) || rc=$?
assert_zero $rc

# ── verify_new_key — retry logic ─────────────────────────────────────────────

describe "verify_new_key — retry behaviour (mock SSH)"

# Create a dummy key file so verify_new_key's path check passes
_VK="${WORK_SSH}/id_ssh-falcon512"
printf 'FAKE_KEY\n' > "${_VK}"
chmod 600 "${_VK}"

# Use a temp file as a cross-subshell call counter; override sleep so retries
# are instant (no wall-clock delay during tests).
_SSH_CALL_FILE="${WORK_DIR}/ssh_call_count"
sleep() { :; }   # disable sleep for all retry tests below

it "succeeds immediately when SSH returns ROTATION_OK on first attempt"
echo "0" > "${_SSH_CALL_FILE}"
_ssh() {
    echo $(( $(cat "${_SSH_CALL_FILE}") + 1 )) > "${_SSH_CALL_FILE}"
    echo "ROTATION_OK"; return 0
}
(verify_new_key "testhost" "22" "testuser" "ssh-falcon512" 2>/dev/null)
assert_zero $?

it "succeeds after 2 initial failures then SSH returns ROTATION_OK"
echo "0" > "${_SSH_CALL_FILE}"
_ssh() {
    local n; n=$(( $(cat "${_SSH_CALL_FILE}") + 1 ))
    echo "$n" > "${_SSH_CALL_FILE}"
    [[ "$n" -ge 3 ]] && { echo "ROTATION_OK"; return 0; }
    return 1
}
(verify_new_key "testhost" "22" "testuser" "ssh-falcon512" 2>/dev/null)
assert_zero $?

it "calls _ssh more than once when early attempts fail"
_count_after="$(cat "${_SSH_CALL_FILE}" 2>/dev/null || echo 0)"
(( _count_after >= 3 )) && pass || fail "_ssh called only ${_count_after} time(s) (counter file), expected ≥ 3"

it "exits non-zero after all retry attempts are exhausted"
_ssh() { return 1; }
rc=0
(verify_new_key "testhost" "22" "testuser" "ssh-falcon512" 2>/dev/null) || rc=$?
assert_nonzero $rc

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
