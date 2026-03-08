#!/bin/bash
set -eo pipefail

# Post-quantum SSH server setup.
#
# Sets up the directory layout, generates OQS host keys (one per selected
# algorithm), writes an sshd_config that advertises all of them, and installs
# a systemd unit.
#
# Algorithm mode:
#   1. All supported PQ algorithms — server accepts every PQ key type the binary
#      knows about; gives clients the widest PQ choice.
#   2. Select specific PQ algorithms — restrict to a particular security level.
#   3. Hybrid — all PQ algorithms + Ed25519 and RSA; interoperates with
#      standard SSH clients while also accepting PQ keys.
#   4. Hybrid — select specific PQ algorithms + Ed25519 and RSA.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

INSTALL_DIR="${BUILD_DIR}"

# ── Directory setup ───────────────────────────────────────────────────────────

setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "${KEY_DIR}"
    mkdir -p "${CONFIG_DIR}"
    mkdir -p ~/.ssh
    mkdir -p "${INSTALL_DIR}/var/run"
    chmod 700 ~/.ssh
}

# ── Host key management ───────────────────────────────────────────────────────

# generate_host_key KEY_TYPE
# Generate (or skip if already present) a single host key pair.
generate_host_key() {
    local key_type="$1"
    local host_key="${KEY_DIR}/ssh_host_${key_type}_key"

    if [[ ! -f "$host_key" ]]; then
        log_cmd "Generate host key (${key_type})" \
            "${BIN_DIR}/ssh-keygen" -t "$key_type" -f "$host_key" -N ""
        log_info "Host key created: $host_key"
    else
        log_info "Host key already exists: $host_key"
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────

# _keytype_to_ssh_algo KEY_TYPE
# Map a key generation type name to one or more SSH algorithm names.
# Classical types have different names in sshd_config directives; PQ types
# are identical to their key type name and pass through unchanged.
_keytype_to_ssh_algo() {
    case "$1" in
        ed25519) echo "ssh-ed25519" ;;
        rsa)     echo "rsa-sha2-512,rsa-sha2-256" ;;
        ecdsa)   echo "ecdsa-sha2-nistp256" ;;
        *)       echo "$1" ;;   # PQ algorithm names pass through unchanged
    esac
}

# create_sshd_config PORT KEYTYPE [KEYTYPE...]
# Write sshd_config with one HostKey line per key type and a comma-separated
# HostKeyAlgorithms / PubkeyAcceptedKeyTypes directive covering all of them.
# Classical types (ed25519, rsa) are mapped to their SSH algorithm names;
# PQ types (ssh-falcon1024, etc.) are used directly.
create_sshd_config() {
    local port="$1"
    shift
    local keytypes=("$@")
    local algo_parts=()
    for kt in "${keytypes[@]}"; do
        algo_parts+=("$(_keytype_to_ssh_algo "$kt")")
    done
    local algo_list
    algo_list="$(IFS=','; echo "${algo_parts[*]}")"

    # Build KexAlgorithms list: always prefer PQ/hybrid KEX first.
    # In a hybrid deployment (classical key types present), append classical KEX
    # so that standard SSH clients can still establish a session.
    local has_classical=false
    for kt in "${keytypes[@]}"; do
        for ck in "${CLASSICAL_KEYTYPES[@]}"; do
            [[ "$kt" == "$ck" ]] && has_classical=true && break 2
        done
    done
    local pq_kex_list kex_list
    pq_kex_list="$(IFS=','; echo "${KEX_ALGORITHMS[*]}")"
    if [[ "$has_classical" == true ]]; then
        kex_list="${pq_kex_list},${CLASSICAL_KEX_ALGORITHMS}"
    else
        kex_list="${pq_kex_list}"
    fi

    {
        echo "Port ${port}"
        for kt in "${keytypes[@]}"; do
            echo "HostKey ${KEY_DIR}/ssh_host_${kt}_key"
        done
        echo "HostKeyAlgorithms ${algo_list}"
        echo "PubkeyAcceptedKeyTypes ${algo_list}"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication no"
        echo "ChallengeResponseAuthentication no"
        echo "AuthenticationMethods publickey"
        echo "KexAlgorithms ${kex_list}"
        echo "AuthorizedKeysFile .ssh/authorized_keys"
        echo "PermitRootLogin no"
        echo "StrictModes yes"
        echo "PidFile ${PID_FILE}"
        echo "Subsystem sftp ${INSTALL_DIR}/libexec/sftp-server"
    } > "${CONFIG_FILE}"

    log_info "Created sshd_config with ${#keytypes[@]} key type(s): ${algo_list}"
}

# ── Systemd service ───────────────────────────────────────────────────────────

create_systemd_service() {
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Post-Quantum SSH Server
After=network.target

[Service]
Type=simple
ExecStart=${SBIN_DIR}/sshd -f ${CONFIG_FILE} -D
Restart=on-failure
RestartSec=5s
StartLimitBurst=3
StartLimitIntervalSec=30s

[Install]
WantedBy=multi-user.target
EOF
    log_info "Created systemd service file"

    log_cmd "systemctl daemon-reload" systemctl daemon-reload
    log_cmd "Enable evaemon-sshd" systemctl enable evaemon-sshd.service
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    # Fail fast if the build hasn't been run yet (L3 fix)
    if [[ ! -x "${BIN_DIR}/ssh-keygen" ]]; then
        log_fatal "OQS-OpenSSH not found at ${BIN_DIR}/ssh-keygen. Please run the build first (option 1 in the wizard)."
    fi

    setup_directories

    # Prompt for port — default 2222 to avoid conflicting with system sshd on 22 (M1 fix)
    local port
    read -rp "SSH listen port [2222]: " port
    port="${port:-2222}"
    validate_port "$port" || log_fatal "Invalid port number: ${port}"
    log_info "Using port ${port}"

    log_section "Algorithm Selection"
    echo "1. All supported PQ algorithms (recommended — broadest PQ client compatibility)"
    echo "2. Select specific PQ algorithms"
    echo "3. Hybrid — all PQ algorithms + Ed25519 and RSA"
    echo "4. Hybrid — select specific PQ algorithms + Ed25519 and RSA"
    read -rp "Mode (1-4) [1]: " mode
    mode="${mode:-1}"

    local selected_keytypes=()
    case "$mode" in
        1)
            selected_keytypes=("${ALGORITHMS[@]}")
            ;;
        2)
            list_algorithms
            read -rp "Enter algorithm numbers (space-separated, e.g. 1 3 5): " -a choices
            for c in "${choices[@]}"; do
                validate_algorithm_choice "$c" "${#ALGORITHMS[@]}" || exit 1
                selected_keytypes+=("${ALGORITHMS[$((c-1))]}")
            done
            if [[ ${#selected_keytypes[@]} -eq 0 ]]; then
                log_fatal "No algorithms selected."
            fi
            ;;
        3)
            selected_keytypes=("${CLASSICAL_KEYTYPES[@]}" "${ALGORITHMS[@]}")
            ;;
        4)
            list_algorithms
            read -rp "Enter PQ algorithm numbers (space-separated, e.g. 1 3 5): " -a choices
            local chosen_pq=()
            for c in "${choices[@]}"; do
                validate_algorithm_choice "$c" "${#ALGORITHMS[@]}" || exit 1
                chosen_pq+=("${ALGORITHMS[$((c-1))]}")
            done
            if [[ ${#chosen_pq[@]} -eq 0 ]]; then
                log_fatal "No PQ algorithms selected."
            fi
            selected_keytypes=("${CLASSICAL_KEYTYPES[@]}" "${chosen_pq[@]}")
            ;;
        *)
            log_fatal "Invalid mode selection."
            ;;
    esac

    log_info "Using ${#selected_keytypes[@]} key type(s):"
    for kt in "${selected_keytypes[@]}"; do
        log_info "  - ${kt}"
    done

    for kt in "${selected_keytypes[@]}"; do
        generate_host_key "$kt"
    done
    create_sshd_config "$port" "${selected_keytypes[@]}"
    create_systemd_service

    log_section "Installation Complete"
    log_info "Active key types:"
    for kt in "${selected_keytypes[@]}"; do
        log_info "  - ${kt}"
    done
    log_info ""
    log_info "Manage the SSH server with:"
    log_info "  systemctl start evaemon-sshd.service"
    log_info "  systemctl stop evaemon-sshd.service"
    log_info "  systemctl status evaemon-sshd.service"
    log_info ""
    log_info "Use the key management script to add client SSH keys."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
