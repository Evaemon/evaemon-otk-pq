#!/bin/bash
# Example: unattended post-quantum key rotation for CI/CD or cron jobs.
#
# This script non-interactively rotates a PQ SSH key on a single server.
# It is intended to be called from a cron job or CI pipeline.
#
# Prerequisites:
#   1. OQS ssh / ssh-keygen built (build_oqs_openssh.sh)
#   2. Current key already authorised on the server
#   3. New key passphrase provided via environment variable EVAEMON_NEW_PASSPHRASE
#      (leave empty / unset for no passphrase -- only for automation accounts)
#
# Usage:
#   EVAEMON_NEW_PASSPHRASE="" bash docs/examples/automated_key_rotation.sh

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SERVER_HOST="${EVAEMON_SERVER_HOST:-192.168.1.10}"
SERVER_PORT="${EVAEMON_SERVER_PORT:-22}"
SERVER_USER="${EVAEMON_SERVER_USER:-alice}"
ALGORITHM="${EVAEMON_ALGORITHM:-ssh-falcon1024}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SSH_BIN="${PROJECT_ROOT}/build/bin/ssh"
KEYGEN_BIN="${PROJECT_ROOT}/build/bin/ssh-keygen"
SSH_DIR="${HOME}/.ssh"
KEY_FILE="${SSH_DIR}/id_${ALGORITHM}"
LOG_PREFIX="[evaemon-rotation]"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "${LOG_PREFIX} $*"; }
die() { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

# ── Input validation ──────────────────────────────────────────────────────────
# Validate env-var inputs before use to prevent injection from untrusted CI env.

_validate_host() {
    local v="$1"
    [[ -n "$v" ]] || die "EVAEMON_SERVER_HOST must not be empty."
    [[ "$v" =~ [[:space:]\;\&\|\`\$\(\)\<\>\'\"] ]] && die "EVAEMON_SERVER_HOST '${v}' contains illegal characters."
    [[ "$v" == *".."* || "$v" == *"/"* ]] && die "EVAEMON_SERVER_HOST '${v}' contains illegal path characters."
    [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || \
       "$v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]] \
        || die "EVAEMON_SERVER_HOST '${v}' is not a valid IP or hostname."
}

_validate_port() {
    local v="$1"
    [[ -n "$v" ]] || die "EVAEMON_SERVER_PORT must not be empty."
    [[ "$v" =~ ^[0-9]+$ ]] || die "EVAEMON_SERVER_PORT '${v}' is not a valid integer."
    (( v >= 1 && v <= 65535 )) || die "EVAEMON_SERVER_PORT '${v}' is out of range (1-65535)."
}

_validate_user() {
    local v="$1"
    [[ -n "$v" ]] || die "EVAEMON_SERVER_USER must not be empty."
    [[ "$v" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || die "EVAEMON_SERVER_USER '${v}' is not a valid POSIX username."
}

_validate_host "$SERVER_HOST"
_validate_port "$SERVER_PORT"
_validate_user "$SERVER_USER"

# PQ KEX algorithms for quantum-safe session key exchange.
# OQS-v10 uses NIST FIPS 203 ML-KEM names (not the old Kyber draft names).
KEX_ALGOS="mlkem1024nistp384-sha384"
KEX_ALGOS="${KEX_ALGOS},mlkem768x25519-sha256"
KEX_ALGOS="${KEX_ALGOS},mlkem768nistp256-sha256"
KEX_ALGOS="${KEX_ALGOS},mlkem1024-sha384"
KEX_ALGOS="${KEX_ALGOS},mlkem768-sha256"

_ssh() {
    "${SSH_BIN}" \
        -o "KexAlgorithms=${KEX_ALGOS}" \
        -o "HostKeyAlgorithms=${ALGORITHM}" \
        -o "PubkeyAcceptedKeyTypes=${ALGORITHM}" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -o "StrictHostKeyChecking=accept-new" \
        -i "$1" \
        -p "${SERVER_PORT}" \
        "${SERVER_USER}@${SERVER_HOST}" \
        "${@:2}"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

[[ -x "$SSH_BIN"    ]] || die "OQS ssh not found at ${SSH_BIN}. Run build_oqs_openssh.sh."
[[ -x "$KEYGEN_BIN" ]] || die "OQS ssh-keygen not found at ${KEYGEN_BIN}."
[[ -f "$KEY_FILE"   ]] || die "Current key not found: ${KEY_FILE}. Cannot authenticate."

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# ── Step 1: Archive the current key ──────────────────────────────────────────
TS="$(date "+%Y%m%d_%H%M%S")"
OLD_KEY_BACKUP="${KEY_FILE}.retired_${TS}"
OLD_PUB_BACKUP="${KEY_FILE}.pub.retired_${TS}"

log "Archiving current key -> ${OLD_KEY_BACKUP}"
cp -p "${KEY_FILE}"      "${OLD_KEY_BACKUP}"
cp -p "${KEY_FILE}.pub"  "${OLD_PUB_BACKUP}"
chmod 400 "${OLD_KEY_BACKUP}" "${OLD_PUB_BACKUP}"

# ── Step 2: Generate a new key ────────────────────────────────────────────────
log "Generating new ${ALGORITHM} key ..."
# Remove old key files before generating new ones
rm -f "${KEY_FILE}" "${KEY_FILE}.pub"

PASSPHRASE="${EVAEMON_NEW_PASSPHRASE:-}"
"${KEYGEN_BIN}" -t "${ALGORITHM}" -f "${KEY_FILE}" -N "${PASSPHRASE}" -q
chmod 600 "${KEY_FILE}"
chmod 644 "${KEY_FILE}.pub"
log "New key generated: ${KEY_FILE}"

# ── Step 3: Push the new public key ──────────────────────────────────────────
log "Pushing new public key to ${SERVER_USER}@${SERVER_HOST} ..."
_ssh "${OLD_KEY_BACKUP}" \
    'mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
     touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
     key=$(cat) && \
     grep -qF "$key" ~/.ssh/authorized_keys 2>/dev/null || \
     printf "%s\n" "$key" >> ~/.ssh/authorized_keys' \
    < "${KEY_FILE}.pub"
log "Public key added to authorized_keys."

# ── Step 4: Verify the new key works ─────────────────────────────────────────
log "Verifying new key ..."
result="$(_ssh "${KEY_FILE}" "echo ROTATION_OK" 2>/dev/null || true)"
if [[ "$result" != "ROTATION_OK" ]]; then
    die "New key verification FAILED. Old key backup retained at ${OLD_KEY_BACKUP}. Investigate before retrying."
fi
log "New key verified successfully."

# ── Step 5: Remove the old key from the server ───────────────────────────────
# Pass key content via stdin to avoid shell injection from key comments.
log "Removing old key from server authorized_keys ..."
_ssh "${KEY_FILE}" \
    'IFS= read -r OLD_KEY
     grep -vF "${OLD_KEY}" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && \
     mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && \
     chmod 600 ~/.ssh/authorized_keys' \
    < "${OLD_PUB_BACKUP}"
log "Old key removed from server."

# ── Step 6: Verify old key is rejected ──────────────────────────────────────
log "Verifying old key is rejected ..."
old_check="$(_ssh "${OLD_KEY_BACKUP}" "echo STILL_ALIVE" 2>/dev/null || true)"
if [[ "$old_check" == *"STILL_ALIVE"* ]]; then
    log "WARNING: Old key still authenticates! Server may have a stale entry."
else
    log "Old key correctly rejected — rotation fully verified."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
log "Key rotation complete."
log "  New key : ${KEY_FILE}"
log "  Old key : ${OLD_KEY_BACKUP} (retained locally; delete after confirming all is well)"
