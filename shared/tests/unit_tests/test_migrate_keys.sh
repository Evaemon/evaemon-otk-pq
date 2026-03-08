#!/bin/bash
# Unit tests for client/migrate_keys.sh
#
# Tests the local scanning functions (scan_authorized_keys, _is_classical_key)
# without requiring an actual OQS binary or SSH connection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
mkdir -p "${WORK_SSH}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Source migrate_keys.sh for its helper functions.
SSH_DIR="${WORK_SSH}"
source "${PROJECT_ROOT}/client/migrate_keys.sh" 2>/dev/null
set +eo pipefail
SSH_DIR="${WORK_SSH}"

# ── _is_classical_key ────────────────────────────────────────────────────────

describe "_is_classical_key — classical key detection"

it "detects ssh-rsa as classical"
_is_classical_key "ssh-rsa AAAAB3... user@host" && pass || fail "ssh-rsa not detected"

it "detects ssh-dss as classical"
_is_classical_key "ssh-dss AAAAB3... user@host" && pass || fail "ssh-dss not detected"

it "detects ecdsa-sha2-nistp256 as classical"
_is_classical_key "ecdsa-sha2-nistp256 AAAAE2... user@host" && pass || fail "ecdsa-nistp256 not detected"

it "detects ecdsa-sha2-nistp384 as classical"
_is_classical_key "ecdsa-sha2-nistp384 AAAAE2... user@host" && pass || fail "ecdsa-nistp384 not detected"

it "detects ecdsa-sha2-nistp521 as classical"
_is_classical_key "ecdsa-sha2-nistp521 AAAAE2... user@host" && pass || fail "ecdsa-nistp521 not detected"

it "detects ssh-ed25519 as classical"
_is_classical_key "ssh-ed25519 AAAAC3... user@host" && pass || fail "ssh-ed25519 not detected"

it "does NOT flag ssh-falcon1024 as classical"
_is_classical_key "ssh-falcon1024 AAAA... user@host" && fail "ssh-falcon1024 flagged as classical" || pass

it "does NOT flag ssh-mldsa-65 as classical"
_is_classical_key "ssh-mldsa-65 AAAA... user@host" && fail "ssh-mldsa-65 flagged as classical" || pass

it "does NOT flag ssh-sphincssha2256fsimple as classical"
_is_classical_key "ssh-sphincssha2256fsimple AAAA... user@host" && fail "sphincs flagged as classical" || pass

it "does NOT flag ssh-slhdsa-sha2-256f as classical"
_is_classical_key "ssh-slhdsa-sha2-256f AAAA... user@host" && fail "slhdsa flagged as classical" || pass

# ── _key_type ────────────────────────────────────────────────────────────────

describe "_key_type — extract key type from authorized_keys line"

it "extracts ssh-rsa from a full line"
result="$(_key_type "ssh-rsa AAAAB3NzaC1yc2EA... user@host")"
assert_eq "ssh-rsa" "$result"

it "extracts ssh-falcon1024 from a full line"
result="$(_key_type "ssh-falcon1024 AAAA... user@host")"
assert_eq "ssh-falcon1024" "$result"

# ── scan_authorized_keys — mixed file ────────────────────────────────────────

describe "scan_authorized_keys — mixed classical and PQ keys"

_AK="${WORK_SSH}/authorized_keys"
cat > "${_AK}" << 'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC... alice@workstation
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... bob@laptop
ssh-falcon1024 AAAAFalcon1024Key... charlie@pq-client
# This is a comment line
ssh-mldsa-65 AAAAMLDSAKey... dave@server
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbm... eve@legacy
EOF

it "returns 0 (migration needed) when classical keys are present"
rc=0
(scan_authorized_keys "${_AK}" 2>/dev/null) || rc=$?
assert_zero $rc

# ── scan_authorized_keys — all PQ ────────────────────────────────────────────

describe "scan_authorized_keys — all post-quantum keys"

_AK_PQ="${WORK_SSH}/authorized_keys_pq"
cat > "${_AK_PQ}" << 'EOF'
ssh-falcon1024 AAAAFalcon1024Key... alice@pq-ws
ssh-mldsa-65 AAAAMLDSAKey... bob@pq-laptop
ssh-sphincssha2256fsimple AAAASPHINCSKey... charlie@pq-server
EOF

it "returns 1 (no migration needed) when all keys are PQ"
rc=0
(scan_authorized_keys "${_AK_PQ}" 2>/dev/null) || rc=$?
assert_nonzero $rc

# ── scan_authorized_keys — empty file ────────────────────────────────────────

describe "scan_authorized_keys — empty file"

_AK_EMPTY="${WORK_SSH}/authorized_keys_empty"
touch "${_AK_EMPTY}"

it "returns 1 when file is empty (no classical keys)"
rc=0
(scan_authorized_keys "${_AK_EMPTY}" 2>/dev/null) || rc=$?
assert_nonzero $rc

# ── scan_authorized_keys — missing file ──────────────────────────────────────

describe "scan_authorized_keys — missing file"

it "returns 2 when file does not exist"
rc=0
(scan_authorized_keys "${WORK_SSH}/nonexistent" 2>/dev/null) || rc=$?
assert_eq "2" "$rc"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
