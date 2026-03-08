#!/bin/bash

# Source config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/validation.sh"

# retry_with_backoff MAX_ATTEMPTS INITIAL_DELAY_S COMMAND [ARGS...]
# Runs COMMAND up to MAX_ATTEMPTS times with exponential backoff between tries.
# Prints a warning on each failure and an error if all attempts are exhausted.
# Returns 0 on first success, 1 if every attempt fails.
retry_with_backoff() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1
    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            log_warn "Attempt ${attempt}/${max_attempts} failed — retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    log_error "All ${max_attempts} attempt(s) failed: $*"
    return 1
}

# _sshd_pid — return the PID of the running evaemon sshd, or empty if not running.
# Checks the PID file first, then falls back to pgrep.
_sshd_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return
        fi
    fi
    pgrep -f "${SBIN_DIR}/sshd" 2>/dev/null | head -1 || true
}

# _configured_port — read the sshd port from CONFIG_FILE, defaulting to 22.
_configured_port() {
    local port="22"
    if [[ -f "$CONFIG_FILE" ]]; then
        local cfg_port
        cfg_port="$(grep -i "^Port " "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' | head -1)"
        [[ -n "$cfg_port" ]] && port="$cfg_port"
    fi
    echo "$port"
}

# Shared functions
list_algorithms() {
    echo "Available algorithms:"
    echo "(Top 3 recommended for multi-family risk diversification)"
    echo
    for i in "${!ALGORITHMS[@]}"; do
        echo "$((i+1)). ${ALGORITHMS[$i]}"
        case ${ALGORITHMS[$i]} in
            "ssh-falcon1024")
                echo "   ↳ ★ Recommended: Fast lattice-based (NTRU), NIST Level 5 security"
                ;;
            "ssh-falcon512")
                echo "   ↳ Falcon variant, NIST Level 1, suitable for constrained devices"
                ;;
            "ssh-mldsa-87")
                echo "   ↳ ML-DSA-87 (NIST FIPS 204), lattice-based, NIST Level 5"
                ;;
            "ssh-mldsa-65")
                echo "   ↳ ★ ML-DSA-65 (NIST FIPS 204), NIST primary standard, Level 3"
                ;;
            "ssh-mldsa-44")
                echo "   ↳ ML-DSA-44 (NIST FIPS 204), lattice-based, NIST Level 2"
                ;;
            "ssh-sphincssha2128fsimple")
                echo "   ↳ SPHINCS+-SHA2-128f (FIPS 205), hash-based, minimal assumptions"
                ;;
            "ssh-sphincssha2256fsimple")
                echo "   ↳ ★ SPHINCS+-SHA2-256f (FIPS 205), hash-based, NIST Level 5"
                ;;
            "ssh-slhdsa-sha2-128f")
                echo "   ↳ SLH-DSA-SHA2-128f (FIPS 205 standardised), hash-based fallback"
                ;;
            "ssh-slhdsa-sha2-256f")
                echo "   ↳ SLH-DSA-SHA2-256f (FIPS 205 standardised), hash-based fallback, Level 5"
                ;;
            "ssh-mayo2")
                echo "   ↳ MAYO-2, oil-and-vinegar multivariate, compact signatures"
                ;;
            "ssh-mayo3")
                echo "   ↳ MAYO-3, oil-and-vinegar multivariate, NIST Level 3"
                ;;
            "ssh-mayo5")
                echo "   ↳ MAYO-5, oil-and-vinegar multivariate, NIST Level 5"
                ;;
        esac
    done
}

# require_oqs_build — abort with a helpful message if OQS-OpenSSH has not
# been built yet.  Call this at the top of any script that invokes binaries
# from ${BIN_DIR} or ${SBIN_DIR}.
require_oqs_build() {
    if [[ ! -x "${BIN_DIR}/ssh" ]]; then
        log_fatal "OQS-OpenSSH is not installed (${BIN_DIR}/ssh not found)." \
                  "Run option 1 — 'Build and install OQS-OpenSSH' — first."
    fi
}