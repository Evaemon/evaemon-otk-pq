#!/bin/bash
set -eo pipefail

# Source shared configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# Populate the script-level PUB_KEYS array and print the numbered list.
# Returns 1 (and exits with an error message) if no keys are found.
_load_and_list_keys() {
    PUB_KEYS=()
    while IFS= read -r -d '' f; do
        PUB_KEYS+=("$f")
    done < <(find "${SSH_DIR}" -maxdepth 1 -name "*.pub" -print0 2>/dev/null | sort -z)
    if [[ ${#PUB_KEYS[@]} -eq 0 ]]; then
        log_error "No public keys found in ${SSH_DIR}. Please generate a key first."
        return 1
    fi
    echo "Available public keys in ${SSH_DIR}:"
    for i in "${!PUB_KEYS[@]}"; do
        echo "$((i+1)). ${PUB_KEYS[$i]}"
    done
}

copy_client_key() {
    local server_host="$1"
    local server_user="$2"
    local public_key_file="$3"
    local server_port="$4"

    validate_file_exists "${public_key_file}" || exit 1
    log_info "Copying public key to ${server_user}@${server_host} via port ${server_port}..."

    # ssh-copy-id reads the key from the file itself, keeping stdin free so
    # SSH can prompt interactively for a password when needed.
    ssh-copy-id -i "${public_key_file}" -p "${server_port}" \
        "${server_user}@${server_host}"
}

main() {
    echo "Copy Client Key to Server"
    echo
    echo "This is the INITIAL BOOTSTRAP step."
    echo "It connects to the server's SYSTEM SSH (standard OpenSSH, usually port 22)"
    echo "using your account PASSWORD to add your PQ public key to authorized_keys."
    echo "Once copied, you can connect to the OQS sshd (e.g. port 2222) using that key."
    echo

    read -rp "Enter the server IP address: " server_host
    validate_ip "$server_host" || exit 1

    read -rp "Enter the server username: " server_user
    validate_username "$server_user" || exit 1

    read -rp "Enter the server's SYSTEM SSH port [22]: " server_port
    server_port=${server_port:-22}
    validate_port "$server_port" || exit 1

    if [[ "$server_port" != "22" ]]; then
        echo
        log_warn "Port ${server_port} is not the standard system SSH port."
        log_warn "This tool uses your system's ssh-copy-id, which only speaks classical SSH."
        log_warn "If port ${server_port} is the OQS sshd, this will fail with a key-type error."
        log_warn "For the bootstrap, use the server's system SSH port (usually 22)."
        read -rp "Continue anyway? (y/N): " cont
        [[ "${cont}" == "y" || "${cont}" == "Y" ]] || exit 0
    fi

    echo
    echo "Select the public key to copy:"
    _load_and_list_keys || exit 1
    read -rp "Select a key by number: " choice
    validate_algorithm_choice "$choice" "${#PUB_KEYS[@]}" || exit 1
    local public_key_file="${PUB_KEYS[$((choice-1))]}"
    log_info "Selected key: ${public_key_file}"

    copy_client_key "${server_host}" "${server_user}" "${public_key_file}" "${server_port}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
