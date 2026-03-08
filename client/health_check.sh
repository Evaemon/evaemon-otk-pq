#!/bin/bash
set -eo pipefail

# Health check tool for post-quantum SSH connections.
# Verifies:
#   1. OQS ssh binary is present and executable
#   2. Requested key file exists with correct permissions
#   3. Remote host is reachable on the given port (TCP probe)
#   4. SSH handshake succeeds with the selected PQ algorithm
#   5. Server host key fingerprint (printed for manual verification)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# ── Check result counters ────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_WARN=0

_pass() { log_info  "  [PASS] $*"; (( _PASS++ )) || true; }
_fail() { log_error "  [FAIL] $*"; (( _FAIL++ )) || true; }
_warn() { log_warn  "  [WARN] $*"; (( _WARN++ )) || true; }

# ── Individual checks ────────────────────────────────────────────────────────

check_binary() {
    log_section "Binary Check"
    if [[ -x "${BIN_DIR}/ssh" ]]; then
        _pass "OQS ssh found at ${BIN_DIR}/ssh"
    else
        _fail "OQS ssh not found at ${BIN_DIR}/ssh -- run build_oqs_openssh.sh first."
    fi
    if [[ -x "${BIN_DIR}/ssh-keygen" ]]; then
        _pass "OQS ssh-keygen found at ${BIN_DIR}/ssh-keygen"
    else
        _warn "OQS ssh-keygen not found at ${BIN_DIR}/ssh-keygen"
    fi
}

check_key() {
    local key_type="$1"
    local key_file="${SSH_DIR}/id_${key_type}"
    log_section "Key Check (${key_type})"

    if [[ ! -f "${key_file}" ]]; then
        _fail "Private key not found: ${key_file}"
        return
    fi
    _pass "Private key exists: ${key_file}"

    if [[ ! -f "${key_file}.pub" ]]; then
        _warn "Public key not found: ${key_file}.pub"
    else
        _pass "Public key exists: ${key_file}.pub"
    fi

    local perms
    perms="$(stat -c "%a" "${key_file}" 2>/dev/null || echo "unknown")"
    if [[ "$perms" == "600" ]]; then
        _pass "Private key permissions are 600"
    else
        _fail "Private key permissions are ${perms} (expected 600) -- fix with: chmod 600 ${key_file}"
    fi
}

check_tcp() {
    local host="$1"
    local port="$2"
    log_section "TCP Reachability (${host}:${port})"

    # Inline retry with exponential backoff (2s → 4s → 8s)
    local attempt=1 delay=2
    while (( attempt <= 3 )); do
        if timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            _pass "TCP connection to ${host}:${port} succeeded"
            return
        fi
        if (( attempt < 3 )); then
            log_warn "TCP probe failed (attempt ${attempt}/3) -- retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    _fail "Cannot reach ${host}:${port} -- check firewall rules and that sshd is running"
}

check_handshake() {
    local host="$1"
    local port="$2"
    local user="$3"
    local algorithm="$4"
    local key_file="${SSH_DIR}/id_${algorithm}"
    log_section "SSH Handshake (${algorithm})"

    if [[ ! -x "${BIN_DIR}/ssh" ]]; then
        _fail "OQS ssh binary missing -- skipping handshake check."
        return
    fi
    if [[ ! -f "$key_file" ]]; then
        _fail "Key file missing -- skipping handshake check."
        return
    fi

    # Retry up to 3 times with exponential backoff (3s → 6s → 12s).
    # Transient failures (network blip, sshd startup lag) should recover.
    local attempt=1 delay=3
    while (( attempt <= 3 )); do
        local output
        if output=$( "${BIN_DIR}/ssh" \
                -o "KexAlgorithms=${PQ_KEX_LIST}" \
                -o "HostKeyAlgorithms=${algorithm}" \
                -o "PubkeyAcceptedKeyTypes=${algorithm}" \
                -o "ConnectTimeout=10" \
                -o "BatchMode=yes" \
                -o "StrictHostKeyChecking=accept-new" \
                -i "${key_file}" \
                -p "${port}" \
                "${user}@${host}" \
                "echo EVAEMON_OK" 2>&1 ); then
            if echo "$output" | grep -q "EVAEMON_OK"; then
                _pass "SSH handshake and authentication succeeded"
                return
            else
                _warn "SSH connected but remote echo failed -- manual inspection recommended"
                return
            fi
        fi
        if (( attempt < 3 )); then
            log_warn "Handshake failed (attempt ${attempt}/3) -- retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    _fail "SSH handshake failed after 3 attempts. Last output: ${output}"
}

check_host_fingerprint() {
    local host="$1"
    local port="$2"
    local algorithm="$3"
    log_section "Server Host Key Fingerprint"

    if [[ ! -x "${BIN_DIR}/ssh-keyscan" ]]; then
        _warn "ssh-keyscan not found -- skipping fingerprint check"
        return
    fi

    local fp
    fp=$( "${BIN_DIR}/ssh-keyscan" -p "${port}" -t "${algorithm}" "${host}" 2>/dev/null \
          | "${BIN_DIR}/ssh-keygen" -lf - 2>/dev/null || true )
    if [[ -n "$fp" ]]; then
        _pass "Host fingerprint retrieved:"
        log_info "    ${fp}"
        log_warn "Verify this fingerprint out-of-band before trusting the server."
    else
        _warn "Could not retrieve host fingerprint (server may not advertise ${algorithm})"
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    log_section "Health Check Summary"
    log_info "  Passed:   ${_PASS}"
    log_warn  "  Warnings: ${_WARN}"
    if [[ $_FAIL -gt 0 ]]; then
        log_error "  Failed:   ${_FAIL}"
        log_error "Health check completed with failures."
        exit 1
    else
        log_info "Health check completed successfully."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_oqs_build
    log_section "Post-Quantum SSH Health Check"

    read -rp "Enter the server host/IP: " server_host
    validate_ip "$server_host" || exit 1

    read -rp "Enter the server username: " server_user
    validate_username "$server_user" || exit 1

    read -rp "Enter the SSH port [22]: " server_port
    server_port="${server_port:-22}"
    validate_port "$server_port" || exit 1

    echo
    list_algorithms
    read -rp "Select algorithm number: " alg_choice
    validate_algorithm_choice "$alg_choice" "${#ALGORITHMS[@]}" || exit 1
    local algorithm="${ALGORITHMS[$((alg_choice-1))]}"

    check_binary
    check_key              "$algorithm"
    check_tcp              "$server_host" "$server_port"
    check_handshake        "$server_host" "$server_port" "$server_user" "$algorithm"
    check_host_fingerprint "$server_host" "$server_port" "$algorithm"
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
