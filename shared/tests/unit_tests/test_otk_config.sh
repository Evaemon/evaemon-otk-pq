#!/bin/bash
# Unit tests for shared/otk_config.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${SCRIPT_DIR}/../../otk_config.sh"

# ── OTK Directory Paths ─────────────────────────────────────────────────────

describe "OTK directory paths"

it "defines OTK_MASTER_DIR"
[[ -n "${OTK_MASTER_DIR}" ]]; assert_zero $?

it "OTK_MASTER_DIR is under SSH_DIR"
assert_contains "${SSH_DIR}" "${OTK_MASTER_DIR}"

it "defines OTK_SESSION_DIR"
[[ -n "${OTK_SESSION_DIR}" ]]; assert_zero $?

it "defines OTK_SERVER_ENROLLED_DIR"
[[ -n "${OTK_SERVER_ENROLLED_DIR}" ]]; assert_zero $?

it "defines OTK_LEDGER_DIR"
[[ -n "${OTK_LEDGER_DIR}" ]]; assert_zero $?

it "defines OTK_LEDGER_FILE"
[[ -n "${OTK_LEDGER_FILE}" ]]; assert_zero $?

it "OTK_LEDGER_FILE is inside OTK_LEDGER_DIR"
assert_contains "${OTK_LEDGER_DIR}" "${OTK_LEDGER_FILE}"

# ── Layer 1: Master Key Algorithms ──────────────────────────────────────────

describe "Layer 1 — Master key algorithms"

it "OTK_MASTER_SIGN_ALGO is set to ML-DSA-87"
assert_eq "ssh-mldsa-87" "${OTK_MASTER_SIGN_ALGO}"

it "OTK_MASTER_KEM_ALGO is set to ML-KEM-1024"
assert_eq "mlkem1024-sha384" "${OTK_MASTER_KEM_ALGO}"

it "OTK_MASTER_SIGN_KEY has a filename"
assert_eq "otk_master_sign" "${OTK_MASTER_SIGN_KEY}"

it "OTK_MASTER_SIGN_PUB has a filename"
assert_eq "otk_master_sign.pub" "${OTK_MASTER_SIGN_PUB}"

# ── Layer 2: Session Key Algorithms ─────────────────────────────────────────

describe "Layer 2 — Session key algorithms"

it "OTK_SESSION_CLASSICAL_SIGN is Ed25519"
assert_eq "ed25519" "${OTK_SESSION_CLASSICAL_SIGN}"

it "OTK_SESSION_CLASSICAL_KEX is curve25519"
assert_eq "curve25519-sha256" "${OTK_SESSION_CLASSICAL_KEX}"

it "OTK_SESSION_PQ_KEX is ML-KEM-1024 hybrid"
assert_eq "mlkem1024nistp384-sha384" "${OTK_SESSION_PQ_KEX}"

it "OTK_SESSION_KEX_LIST starts with PQ KEX"
assert_contains "mlkem1024nistp384-sha384" "${OTK_SESSION_KEX_LIST}"

it "OTK_SESSION_KEX_LIST includes classical fallback"
assert_contains "curve25519-sha256" "${OTK_SESSION_KEX_LIST}"

it "OTK_SESSION_KDF is SHA-512"
assert_eq "SHA-512" "${OTK_SESSION_KDF}"

# ── Layer 3: One-Time Execution Parameters ──────────────────────────────────

describe "Layer 3 — One-time execution parameters"

it "OTK_NONCE_MAX_AGE defaults to 300 seconds"
assert_eq "300" "${OTK_NONCE_MAX_AGE}"

it "OTK_NONCE_RANDOM_BYTES defaults to 32"
assert_eq "32" "${OTK_NONCE_RANDOM_BYTES}"

it "OTK_LEDGER_PRUNE_DAYS defaults to 7"
assert_eq "7" "${OTK_LEDGER_PRUNE_DAYS}"

it "OTK_LEDGER_MAX_ENTRIES defaults to 100000"
assert_eq "100000" "${OTK_LEDGER_MAX_ENTRIES}"

it "OTK_REVOCATION_HASH is SHA3-256"
assert_eq "sha3-256" "${OTK_REVOCATION_HASH}"

it "OTK_SHRED_PASSES defaults to 3"
assert_eq "3" "${OTK_SHRED_PASSES}"

# ── Permissions ──────────────────────────────────────────────────────────────

describe "OTK permissions"

it "OTK_DIR_PERMS is 700"
assert_eq "700" "${OTK_DIR_PERMS}"

it "OTK_PRIVATE_KEY_PERMS is 600"
assert_eq "600" "${OTK_PRIVATE_KEY_PERMS}"

it "OTK_PUBLIC_KEY_PERMS is 644"
assert_eq "644" "${OTK_PUBLIC_KEY_PERMS}"

it "OTK_LEDGER_PERMS is 600"
assert_eq "600" "${OTK_LEDGER_PERMS}"

# ── Master Key Rotation ─────────────────────────────────────────────────────

describe "Master key rotation"

it "OTK_MASTER_MAX_AGE_DAYS defaults to 365"
assert_eq "365" "${OTK_MASTER_MAX_AGE_DAYS}"

# ── Base config inherited ───────────────────────────────────────────────────

describe "Base config inheritance"

it "PROJECT_ROOT is set (from config.sh)"
[[ -n "${PROJECT_ROOT}" ]]; assert_zero $?

it "BUILD_DIR is set (from config.sh)"
[[ -n "${BUILD_DIR}" ]]; assert_zero $?

it "BIN_DIR is set (from config.sh)"
[[ -n "${BIN_DIR}" ]]; assert_zero $?

it "SSH_DIR is set (from config.sh)"
[[ -n "${SSH_DIR}" ]]; assert_zero $?

it "ALGORITHMS array is populated (from config.sh)"
[[ ${#ALGORITHMS[@]} -gt 0 ]]; assert_zero $?

test_summary
