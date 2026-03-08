#!/bin/bash
set -eo pipefail

# Source shared configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# Determine the real (non-root) user for chown/sudo -u calls.
# SSH_DIR is already resolved to the correct home by config.sh.
if [[ -n "${SUDO_USER}" ]]; then
    REAL_USER="${SUDO_USER}"
else
    REAL_USER="$(whoami)"
fi

# Function for key generation
generate_key() {
    local key_type=$1
    local key_file="${SSH_DIR}/id_${key_type}"
    
    # Create .ssh directory if it doesn't exist
    if [[ ! -d "${SSH_DIR}" ]]; then
        mkdir -p "${SSH_DIR}"
        chmod 700 "${SSH_DIR}"
        chown "${REAL_USER}:${REAL_USER}" "${SSH_DIR}" 2>/dev/null || true
    fi
    
    log_info "Generating ${key_type} key..."
    if [[ -f "${key_file}" || -f "${key_file}.pub" ]]; then
        read -rp "Key already exists. Overwrite? (y/N): " overwrite
        if [[ "${overwrite}" != "y" && "${overwrite}" != "Y" ]]; then
            log_info "Skipping key generation."
            return
        fi
    fi

    read -rp "Do you want to protect this key with a password? (y/N): " use_password
    if [[ "${use_password}" == "y" || "${use_password}" == "Y" ]]; then
        log_cmd "ssh-keygen (with passphrase)" \
            sudo -u "${REAL_USER}" "${BIN_DIR}/ssh-keygen" -t "${key_type}" -f "${key_file}"
    else
        log_cmd "ssh-keygen (no passphrase)" \
            sudo -u "${REAL_USER}" "${BIN_DIR}/ssh-keygen" -t "${key_type}" -f "${key_file}" -N ""
    fi

    # Ensure correct ownership and permissions
    chown "${REAL_USER}:${REAL_USER}" "${key_file}"* 2>/dev/null
    chmod 600 "${key_file}" 2>/dev/null
    chmod 644 "${key_file}.pub" 2>/dev/null

    log_info "Key generated at ${key_file}."
}

# Main function
main() {
    require_oqs_build
    echo "Select key type:"
    echo "1. Post-quantum key"
    echo "2. Classical key (Ed25519 or RSA)"
    read -rp "Mode (1-2) [1]: " keygen_mode
    keygen_mode="${keygen_mode:-1}"

    local key_type
    case "$keygen_mode" in
        1)
            list_algorithms
            read -rp "Select an algorithm by number (1-${#ALGORITHMS[@]}): " choice
            validate_algorithm_choice "$choice" "${#ALGORITHMS[@]}" || exit 1
            key_type="${ALGORITHMS[$((choice-1))]}"
            ;;
        2)
            echo "Select classical key type:"
            echo "1. Ed25519 (recommended)"
            echo "2. RSA"
            read -rp "Type (1-2) [1]: " classical_choice
            classical_choice="${classical_choice:-1}"
            case "$classical_choice" in
                1) key_type="ed25519" ;;
                2) key_type="rsa" ;;
                *) log_fatal "Invalid classical key type selection." ;;
            esac
            ;;
        *)
            log_fatal "Invalid mode selection."
            ;;
    esac

    generate_key "${key_type}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi