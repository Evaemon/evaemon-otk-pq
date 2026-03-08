#!/bin/bash
# Unit tests for server/monitoring.sh — show_security_report()
#
# Creates synthetic sshd_config files and verifies the quantum readiness
# scoring logic.  No running sshd or OQS binary required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area
WORK_DIR="$(mktemp -d)"
mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/var/run"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Override globals so monitoring.sh reads our synthetic configs
BUILD_DIR="${WORK_DIR}"
CONFIG_DIR="${WORK_DIR}/etc"
CONFIG_FILE="${CONFIG_DIR}/sshd_config"
KEY_DIR="${WORK_DIR}/etc/keys"
PID_FILE="${WORK_DIR}/var/run/sshd.pid"
SERVICE_NAME="evaemon-test-sshd"

source "${PROJECT_ROOT}/server/monitoring.sh" 2>/dev/null
set +eo pipefail

# Override globals again after sourcing (config.sh may reset them)
BUILD_DIR="${WORK_DIR}"
CONFIG_DIR="${WORK_DIR}/etc"
CONFIG_FILE="${CONFIG_DIR}/sshd_config"

# Helper: write a synthetic sshd_config and capture the report output
_run_report() {
    show_security_report 2>&1
}

# ── Full PQ config (multi-family + pure KEX + password disabled) ────────────

describe "show_security_report — full PQ config"

cat > "${CONFIG_FILE}" << 'EOF'
Port 2222
HostKeyAlgorithms ssh-falcon1024,ssh-mldsa-65,ssh-sphincssha2256fsimple
PubkeyAcceptedKeyTypes ssh-falcon1024,ssh-mldsa-65,ssh-sphincssha2256fsimple
KexAlgorithms mlkem1024nistp384-sha384,mlkem768x25519-sha256,mlkem1024-sha384,mlkem768-sha256
PasswordAuthentication no
EOF

it "reports 100% readiness for ideal multi-family config"
output="$(_run_report)"
[[ "$output" == *"100%"* ]] && pass || fail "expected 100% in output, got: $(echo "$output" | grep readiness)"

it "labels readiness as EXCELLENT"
output="$(_run_report)"
[[ "$output" == *"EXCELLENT"* ]] && pass || fail "expected EXCELLENT label"

it "shows the current negotiated algo line"
output="$(_run_report)"
[[ "$output" == *"ssh-falcon1024"* && "$output" == *"mlkem"* ]] && pass || fail "missing negotiated algo"

it "checks lattice host key box"
output="$(_run_report)"
[[ "$output" == *"[x] Lattice"* ]] && pass || fail "lattice checkbox missing"

it "checks hash-based host key box"
output="$(_run_report)"
[[ "$output" == *"[x] Hash-based"* ]] && pass || fail "hash-based checkbox missing"

# ── Single-algorithm PQ config ──────────────────────────────────────────────

describe "show_security_report — single PQ algorithm"

cat > "${CONFIG_FILE}" << 'EOF'
Port 2222
HostKeyAlgorithms ssh-falcon1024
KexAlgorithms mlkem1024nistp384-sha384
PasswordAuthentication no
EOF

it "scores lower for single-family (no hash-based, no ML-DSA)"
output="$(_run_report)"
# Should have: PQ host (30) + PQ KEX (20) + password disabled (10) = 60
# Missing: multi-family (0) + ML-DSA (0) + hash-based (0) + pure KEX (0)
[[ "$output" == *"60%"* ]] && pass || fail "expected 60% for single-family, got: $(echo "$output" | grep readiness)"

it "shows recommendations for missing features"
output="$(_run_report)"
[[ "$output" == *"Recommendations"* ]] && pass || fail "expected recommendations section"

# ── Classical-only config ───────────────────────────────────────────────────

describe "show_security_report — classical-only config"

cat > "${CONFIG_FILE}" << 'EOF'
Port 22
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512
PasswordAuthentication yes
EOF

it "scores 0% for purely classical config"
output="$(_run_report)"
[[ "$output" == *"0%"* ]] && pass || fail "expected 0% for classical config, got: $(echo "$output" | grep readiness)"

it "labels as NEEDS IMPROVEMENT"
output="$(_run_report)"
[[ "$output" == *"NEEDS IMPROVEMENT"* ]] && pass || fail "expected NEEDS IMPROVEMENT label"

# ── Missing config file ────────────────────────────────────────────────────

describe "show_security_report — missing config file"

rm -f "${CONFIG_FILE}"

it "handles missing sshd_config gracefully"
output="$(_run_report)"
[[ "$output" == *"cannot assess"* ]] && pass || fail "expected warning about missing config"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
