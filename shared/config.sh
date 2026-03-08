#!/bin/bash

# Get the actual project root directory (parent of this script)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build directories
BUILD_DIR="${PROJECT_ROOT}/build"
BIN_DIR="${BUILD_DIR}/bin"
SBIN_DIR="${BUILD_DIR}/sbin"
PREFIX="${BUILD_DIR}/oqs"
INSTALL_PREFIX="${BUILD_DIR}"

# Repository information
LIBOQS_REPO="https://github.com/open-quantum-safe/liboqs.git"
# OQS-OpenSSH OQS-v10 (based on OpenSSH 10.2) uses liboqs main at build time.
# Pin to the latest stable release; 0.11.0 is the minimum that includes
# ML-KEM, ML-DSA (FIPS 204), and MAYO support.
LIBOQS_BRANCH="0.11.0"

OPENSSH_REPO="https://github.com/open-quantum-safe/openssh.git"
OPENSSH_BRANCH="OQS-v10"

# System directories
OPENSSL_SYS_DIR="/usr"
# When a script is invoked via sudo, $HOME resolves to /root rather than the
# invoking user's home directory.  Use $SUDO_USER (set by sudo) to find the
# real home so all scripts consistently look in the correct ~/.ssh directory.
if [[ -n "${SUDO_USER}" ]]; then
    _sudo_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    if [[ -z "${_sudo_home}" ]]; then
        echo "ERROR: cannot resolve home directory for SUDO_USER='${SUDO_USER}'" >&2
        exit 1
    fi
    SSH_DIR="${_sudo_home}/.ssh"
    unset _sudo_home
else
    SSH_DIR="${HOME}/.ssh"
fi

# Supported algorithms — names must match OQS-OpenSSH OQS-v10 / liboqs 0.11.0+.
# OQS-v10 dropped the old Dilithium and SPHINCS+-haraka/robust names:
#   dilithium2/3/5        → mldsa-44/65/87  (NIST FIPS 204 / ML-DSA)
#   sphincsharaka*        → removed entirely
#   sphincssha256*robust  → sphincssha2*fsimple
#
# Ordering: multi-family risk diversification — top 3 from different families:
#   1. Falcon-1024    — lattice (NTRU), fastest verification, compact at L5
#   2. ML-DSA-65      — lattice (Module-LWE), NIST FIPS 204 primary standard
#   3. SPHINCS+-256f  — hash-based (FIPS 205), minimal cryptographic assumptions
#   4. SLH-DSA-256f   — standardised FIPS 205 name (liboqs ≥ 0.12.0)
# This ensures a break in any single mathematical assumption family does not
# compromise all deployed keys simultaneously.
ALGORITHMS=(
    "ssh-falcon1024"
    "ssh-mldsa-65"
    "ssh-sphincssha2256fsimple"
    "ssh-slhdsa-sha2-256f"
    "ssh-mldsa-87"
    "ssh-mldsa-44"
    "ssh-sphincssha2128fsimple"
    "ssh-slhdsa-sha2-128f"
    "ssh-falcon512"
    "ssh-mayo2"
    "ssh-mayo3"
    "ssh-mayo5"
)

# Maximum key age in days before rotation is enforced.
KEY_MAX_AGE_DAYS="${KEY_MAX_AGE_DAYS:-90}"

# Classical key types that the migration scanner flags for replacement.
CLASSICAL_KEY_PATTERNS=("ssh-rsa" "ssh-dss" "ecdsa-sha2-nistp256" "ecdsa-sha2-nistp384" "ecdsa-sha2-nistp521" "ssh-ed25519")

# Classical key types for hybrid mode (passed to ssh-keygen -t)
CLASSICAL_KEYTYPES=("ed25519" "rsa")

# Classical SSH algorithm names for sshd_config directives (HostKeyAlgorithms etc.)
CLASSICAL_HOST_ALGOS="ssh-ed25519,rsa-sha2-512,rsa-sha2-256"

# Post-quantum and hybrid key exchange algorithms (for KexAlgorithms directive).
# OQS-v10 uses ML-KEM (NIST FIPS 203) names; the old kyber-*r3-*-d00 draft
# names from OQS-v9 are no longer recognised by the binary.
# Hybrid variants (mlkem*nistp*/x25519) are preferred: they are quantum-safe
# AND classically-secure, so security cannot regress even if ML-KEM is broken.
KEX_ALGORITHMS=(
    "mlkem1024nistp384-sha384"
    "mlkem768x25519-sha256"
    "mlkem768nistp256-sha256"
    "mlkem1024-sha384"
    "mlkem768-sha256"
)

# Pre-computed comma-separated PQ KEX list for SSH client -o KexAlgorithms=...
# Every SSH invocation in the toolkit should include this to ensure the session
# key exchange is quantum-safe, not just the authentication.
PQ_KEX_LIST="$(IFS=','; echo "${KEX_ALGORITHMS[*]}")"

# Classical key exchange algorithms appended in hybrid server deployments so
# standard (non-OQS) SSH clients can still connect alongside PQ clients.
# Note: diffie-hellman-group14-sha256 (2048-bit DH) is intentionally excluded
# — it is deprecated per NIST SP 800-77r1; group16 (4096-bit) is the minimum.
CLASSICAL_KEX_ALGORITHMS="curve25519-sha256,ecdh-sha2-nistp384,diffie-hellman-group16-sha512"

# Server paths — shared across server setup, monitoring, update, and diagnostics
KEY_DIR="${BUILD_DIR}/etc/keys"
CONFIG_DIR="${BUILD_DIR}/etc"
CONFIG_FILE="${CONFIG_DIR}/sshd_config"
PID_FILE="${BUILD_DIR}/var/run/sshd.pid"
SERVICE_NAME="evaemon-sshd"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"