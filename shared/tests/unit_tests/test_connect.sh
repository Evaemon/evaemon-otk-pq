#!/bin/bash
# Unit tests for client/connect.sh — connect()
#
# The real BIN_DIR/ssh binary is replaced with a mock that records the
# arguments it receives.  All validation helpers and list_algorithms() are
# stubbed so no server, keys, or OQS binaries are required.
#
# User input is supplied via stdin heredoc: one line per read -p prompt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# ── Isolated scratch area ─────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
MOCK_BIN="${WORK_DIR}/bin"
MOCK_ARGS_FILE="${WORK_DIR}/mock_ssh_args"
mkdir -p "${WORK_SSH}" "${MOCK_BIN}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ── Mock SSH binary ───────────────────────────────────────────────────────────
# Writes one argument per line to MOCK_ARGS_FILE and exits 0.

cat > "${MOCK_BIN}/ssh" << MOCK_SCRIPT
#!/bin/bash
printf '%s\n' "\$@" > "${MOCK_ARGS_FILE}"
exit 0
MOCK_SCRIPT
chmod +x "${MOCK_BIN}/ssh"

# ── Source connect.sh ─────────────────────────────────────────────────────────
# Override BIN_DIR and SSH_DIR before sourcing; re-assert after config.sh
# re-sources itself.  set +eo pipefail prevents the harness from aborting on
# expected non-zero exits.

BIN_DIR="${MOCK_BIN}"
SSH_DIR="${WORK_SSH}"
source "${PROJECT_ROOT}/client/connect.sh" 2>/dev/null
set +eo pipefail
BIN_DIR="${MOCK_BIN}"
SSH_DIR="${WORK_SSH}"

# ── Stub interactive helpers ──────────────────────────────────────────────────
validate_ip()               { return 0; }
validate_username()         { return 0; }
validate_port()             { return 0; }
validate_algorithm_choice() { return 0; }
validate_file_exists()      { return 0; }
list_algorithms()           { :; }

# ── Invoke connect() for PQ-only mode ────────────────────────────────────────
# Inputs (one per read -p):
#   server_host → 192.168.10.5
#   username    → alice
#   port        → 2222
#   conn_mode   → 1  (PQ only)
#   choice      → 1  (first algorithm = ssh-falcon1024)

connect <<< $'192.168.10.5\nalice\n2222\n1\n1' 2>/dev/null
_PQ_ARGS="$(cat "${MOCK_ARGS_FILE}" 2>/dev/null || echo "")"

# ── PQ-only mode SSH argument checks ─────────────────────────────────────────

describe "connect — PQ-only mode (mode 1)"

it "passes KexAlgorithms option to ssh"
assert_contains "KexAlgorithms=" "$_PQ_ARGS"

it "KexAlgorithms contains an ML-KEM algorithm"
assert_contains "mlkem" "$_PQ_ARGS"

it "KexAlgorithms does not contain classical-only curve25519-sha256"
echo "$_PQ_ARGS" | grep -q "KexAlgorithms=.*curve25519-sha256" \
    && fail "PQ-only KexAlgorithms unexpectedly includes curve25519-sha256" || pass

it "passes HostKeyAlgorithms option to ssh"
assert_contains "HostKeyAlgorithms=" "$_PQ_ARGS"

it "HostKeyAlgorithms contains the selected PQ algorithm"
assert_contains "${ALGORITHMS[0]}" "$_PQ_ARGS"

it "passes PubkeyAcceptedKeyTypes option to ssh"
assert_contains "PubkeyAcceptedKeyTypes=" "$_PQ_ARGS"

it "passes -i flag (identity file) to ssh"
assert_contains "-i" "$_PQ_ARGS"

it "passes -p flag (port) to ssh"
assert_contains "-p" "$_PQ_ARGS"

it "passes user@host to ssh"
assert_contains "alice@192.168.10.5" "$_PQ_ARGS"

# ── Invoke connect() for hybrid mode ─────────────────────────────────────────
# Inputs:
#   server_host → 192.168.10.5
#   username    → alice
#   port        → 2222
#   conn_mode   → 2  (hybrid)
#   choice      → 1  (ssh-falcon1024)

connect <<< $'192.168.10.5\nalice\n2222\n2\n1' 2>/dev/null
_HY_ARGS="$(cat "${MOCK_ARGS_FILE}" 2>/dev/null || echo "")"

# ── Hybrid mode SSH argument checks ──────────────────────────────────────────

describe "connect — hybrid mode (mode 2)"

it "passes KexAlgorithms option to ssh"
assert_contains "KexAlgorithms=" "$_HY_ARGS"

it "hybrid KexAlgorithms contains an ML-KEM algorithm"
assert_contains "mlkem" "$_HY_ARGS"

it "hybrid KexAlgorithms contains classical fallback curve25519-sha256"
assert_contains "curve25519-sha256" "$_HY_ARGS"

it "hybrid HostKeyAlgorithms contains the PQ algorithm"
assert_contains "${ALGORITHMS[0]}" "$_HY_ARGS"

it "hybrid HostKeyAlgorithms contains ssh-ed25519"
assert_contains "ssh-ed25519" "$_HY_ARGS"

it "passes user@host to ssh"
assert_contains "alice@192.168.10.5" "$_HY_ARGS"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
