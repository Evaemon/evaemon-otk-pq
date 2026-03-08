#!/bin/bash
# Unit tests for client/copy_key_to_server.sh — copy_client_key()
#
# copy_client_key() uses the system's ssh-copy-id (not the OQS ssh binary)
# because this is the BOOTSTRAP step: it connects via classical SSH to push
# the PQ public key.  The mock replaces ssh-copy-id on PATH and records
# the arguments it receives.  No server or OQS binary is required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
MOCK_BIN="${WORK_DIR}/bin"
MOCK_ARGS_FILE="${WORK_DIR}/mock_ssh_copy_id_args"
mkdir -p "${WORK_SSH}" "${MOCK_BIN}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ── Create mock ssh-copy-id binary ───────────────────────────────────────────
# The mock writes one argument per line to MOCK_ARGS_FILE and exits 0.
# copy_client_key() calls: ssh-copy-id -i PUBKEY -p PORT user@host

cat > "${MOCK_BIN}/ssh-copy-id" << MOCK_SCRIPT
#!/bin/bash
printf '%s\n' "\$@" > "${MOCK_ARGS_FILE}"
exit 0
MOCK_SCRIPT
chmod +x "${MOCK_BIN}/ssh-copy-id"

# Put the mock directory first on PATH so our mock is found before system ssh-copy-id
export PATH="${MOCK_BIN}:${PATH}"

# Source copy_key_to_server.sh for its functions.
# The BASH_SOURCE guard prevents main() from running.
BIN_DIR="${MOCK_BIN}"
SSH_DIR="${WORK_SSH}"
source "${PROJECT_ROOT}/client/copy_key_to_server.sh" 2>/dev/null
set +eo pipefail
# Re-assert our overrides (config.sh re-sources itself inside the script)
SSH_DIR="${WORK_SSH}"
BIN_DIR="${MOCK_BIN}"

# ── Fixture: fake public key ────────────────────────────────────────────────
_PUB="${WORK_SSH}/id_ssh-falcon1024.pub"
printf 'ssh-falcon1024 FAKEBASE64 unit-test-key\n' > "${_PUB}"

_ALGO="ssh-falcon1024"
_HOST="192.168.10.20"
_USER="alice"
_PORT="2222"

# Invoke copy_client_key and capture mock args for inspection.
# copy_client_key takes: HOST USER PUB PORT (4 args — no algo parameter)
copy_client_key "${_HOST}" "${_USER}" "${_PUB}" "${_PORT}" 2>/dev/null
_ARGS="$(cat "${MOCK_ARGS_FILE}" 2>/dev/null || echo "")"

# ── Argument checks ─────────────────────────────────────────────────────────
# ssh-copy-id receives: -i PUBKEY -p PORT user@host

describe "copy_client_key — ssh-copy-id argument verification"

it "passes -i flag (identity file) to ssh-copy-id"
assert_contains "-i" "$_ARGS"

it "passes the public key file path to ssh-copy-id"
assert_contains "${_PUB}" "$_ARGS"

it "passes -p flag to ssh-copy-id"
assert_contains "-p" "$_ARGS"

it "passes the correct port number to ssh-copy-id"
assert_contains "${_PORT}" "$_ARGS"

it "passes user@host to ssh-copy-id"
assert_contains "${_USER}@${_HOST}" "$_ARGS"

# ── Key file content check ──────────────────────────────────────────────────
# ssh-copy-id reads the key from -i file, so verify the fixture is correct

describe "copy_client_key — public key file"

it "public key file exists and is non-empty"
[[ -s "${_PUB}" ]] && pass || fail "public key file is empty or missing"

it "public key file contains the algorithm name"
content="$(cat "${_PUB}")"
assert_contains "ssh-falcon1024" "$content"

it "public key file content matches the fixture"
expected="ssh-falcon1024 FAKEBASE64 unit-test-key"
actual="$(cat "${_PUB}")"
assert_eq "$expected" "$actual"

# ── Failure path ────────────────────────────────────────────────────────────

describe "copy_client_key — missing public key"

it "exits non-zero when the public key file does not exist"
rc=0
(copy_client_key "${_HOST}" "${_USER}" "${WORK_SSH}/nonexistent.pub" "${_PORT}" \
    2>/dev/null) || rc=$?
assert_nonzero $rc

it "does not invoke ssh-copy-id when the public key file is missing"
rm -f "${MOCK_ARGS_FILE}"
(copy_client_key "${_HOST}" "${_USER}" "${WORK_SSH}/gone.pub" "${_PORT}" \
    2>/dev/null) || true
[[ ! -f "${MOCK_ARGS_FILE}" ]] && pass || fail "mock ssh-copy-id was invoked despite missing key file"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
