#!/bin/bash
set -eo pipefail

# Source shared configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# _check_classical_keys_on_server HOST PORT USER KEY ALGO
# Probes the server's authorized_keys for classical (non-PQ) key types and
# prints a migration warning.  Runs before the interactive SSH session so the
# user sees the warning immediately.  Failures are silently ignored (the probe
# is best-effort and must never block the actual connection).
_check_classical_keys_on_server() {
    local host="$1" port="$2" user="$3" key="$4" algo="$5"

    local ak_content
    ak_content="$(SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${PQ_KEX_LIST}" \
        -o "HostKeyAlgorithms=${algo}" \
        -o "PubkeyAcceptedKeyTypes=${algo}" \
        -o "ConnectTimeout=10" \
        -o "BatchMode=yes" \
        -i "${key}" \
        -p "${port}" \
        "${user}@${host}" \
        "cat ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null || true)"

    [[ -z "$ak_content" ]] && return 0

    local classical_found=false classical_types=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "#"* ]] && continue
        for pattern in "${CLASSICAL_KEY_PATTERNS[@]}"; do
            if [[ "$line" == "${pattern} "* ]]; then
                classical_found=true
                local already=false
                for existing in "${classical_types[@]+"${classical_types[@]}"}"; do
                    [[ "$existing" == "$pattern" ]] && already=true
                done
                $already || classical_types+=("$pattern")
            fi
        done
    done <<< "$ak_content"

    if $classical_found; then
        echo
        log_warn "MIGRATION WARNING: Classical SSH keys detected on ${user}@${host}:"
        for t in "${classical_types[@]}"; do
            log_warn "  - ${t}"
        done
        log_warn "These keys are vulnerable to quantum attacks."
        log_warn "Run 'bash client/migrate_keys.sh' to scan and migrate."
        echo
    fi

    return 0
}

connect() {
    require_oqs_build
    echo "Post-Quantum SSH Connection Tool"
    echo "--------------------------------"

    read -rp "Enter the server host/IP: " server_host
    validate_ip "$server_host" || exit 1

    read -rp "Enter the username: " username
    validate_username "$username" || exit 1

    read -rp "Enter the SSH port [22]: " port
    port=${port:-22}
    validate_port "$port" || exit 1

    echo
    echo "Select connection mode:"
    echo "1. Post-quantum only"
    echo "2. Hybrid (post-quantum + classical)"
    read -rp "Mode (1-2) [1]: " conn_mode
    conn_mode="${conn_mode:-1}"

    echo
    echo "Select the post-quantum algorithm:"
    list_algorithms
    read -rp "Enter algorithm number: " choice
    validate_algorithm_choice "$choice" "${#ALGORITHMS[@]}" || exit 1

    algorithm="${ALGORITHMS[$((choice-1))]}"
    key_path="${SSH_DIR}/id_${algorithm}"
    validate_file_exists "$key_path" || log_fatal "Key file not found: ${key_path}. Generate a key first."

    # Pre-connect: probe for classical keys and warn the user.
    _check_classical_keys_on_server \
        "$server_host" "$port" "$username" "$key_path" "$algorithm" || true

    case "$conn_mode" in
        1)
            log_info "Connecting to ${username}@${server_host} using ${algorithm}..."
            SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
                -o "KexAlgorithms=${PQ_KEX_LIST}" \
                -o "HostKeyAlgorithms=${algorithm}" \
                -o "PubkeyAcceptedKeyTypes=${algorithm}" \
                -i "${key_path}" \
                -p "${port}" \
                "${username}@${server_host}"
            ;;
        2)
            # In hybrid mode, KexAlgorithms and HostKeyAlgorithms include both
            # PQ and classical algorithms so the client interoperates with hybrid
            # servers.  User authentication still uses the PQ key.
            hybrid_algos="${algorithm},${CLASSICAL_HOST_ALGOS}"
            hybrid_kex="${PQ_KEX_LIST},${CLASSICAL_KEX_ALGORITHMS}"
            log_info "Connecting to ${username}@${server_host} using hybrid mode (${algorithm} + classical)..."
            SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
                -o "KexAlgorithms=${hybrid_kex}" \
                -o "HostKeyAlgorithms=${hybrid_algos}" \
                -o "PubkeyAcceptedKeyTypes=${hybrid_algos}" \
                -i "${key_path}" \
                -p "${port}" \
                "${username}@${server_host}"
            ;;
        *)
            log_fatal "Invalid mode selection."
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    connect
fi