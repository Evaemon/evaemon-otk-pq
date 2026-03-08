#!/bin/bash
set -eo pipefail

# Post-quantum key migration tool.
#
# Scans ~/.ssh/authorized_keys on a remote server (or locally) for classical
# (non-PQ) key types and reports which keys need migration.  Optionally
# generates a replacement PQ key and pushes it to the server.
#
# Classical key types detected:
#   ssh-rsa, ssh-dss, ecdsa-sha2-*, ssh-ed25519
#
# Usage:
#   bash client/migrate_keys.sh              # interactive wizard
#   bash client/migrate_keys.sh --local      # scan local authorized_keys only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

_ssh() {
    local key="$1"; shift
    local algo="$1"; shift
    "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${PQ_KEX_LIST}" \
        -o "HostKeyAlgorithms=${algo}" \
        -o "PubkeyAcceptedKeyTypes=${algo}" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -i "${key}" \
        "$@"
}

# _is_classical_key LINE
# Returns 0 if the line starts with a classical key type prefix.
_is_classical_key() {
    local line="$1"
    for pattern in "${CLASSICAL_KEY_PATTERNS[@]}"; do
        if [[ "$line" == "${pattern} "* ]]; then
            return 0
        fi
    done
    return 1
}

# _key_type LINE
# Extract the key type (first field) from an authorized_keys line.
_key_type() {
    echo "$1" | awk '{print $1}'
}

# _key_comment LINE
# Extract the comment (third field onwards) from an authorized_keys line.
_key_comment() {
    echo "$1" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}'
}

# ── Scan Functions ───────────────────────────────────────────────────────────

# scan_authorized_keys FILE
# Reads an authorized_keys file and reports classical vs PQ keys.
# Returns 0 if classical keys were found (migration needed), 1 if all PQ.
scan_authorized_keys() {
    local ak_file="$1"
    local classical_count=0
    local pq_count=0
    local total=0
    local classical_keys=()

    if [[ ! -f "$ak_file" ]]; then
        log_error "File not found: ${ak_file}"
        return 2
    fi

    log_section "Scanning ${ak_file} for Classical Keys"

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* ]] && continue
        (( total++ )) || true

        local ktype
        ktype="$(_key_type "$line")"
        local comment
        comment="$(_key_comment "$line")"

        if _is_classical_key "$line"; then
            (( classical_count++ )) || true
            classical_keys+=("${ktype}  ${comment}")
            log_warn "CLASSICAL: ${ktype}  ${comment}"
        else
            (( pq_count++ )) || true
            log_success "PQ:        ${ktype}  ${comment}"
        fi
    done < "$ak_file"

    echo
    log_info "─── Summary ───"
    log_info "Total keys:     ${total}"
    log_info "Post-quantum:   ${pq_count}"

    if (( classical_count > 0 )); then
        log_warn "Classical:      ${classical_count}  ← MIGRATION NEEDED"
        echo
        log_warn "The following classical keys are vulnerable to quantum attacks:"
        for ck in "${classical_keys[@]}"; do
            log_warn "  - ${ck}"
        done
        return 0
    else
        log_success "Classical:      0  — All keys are post-quantum!"
        return 1
    fi
}

# scan_remote HOST PORT USER PQ_KEY PQ_ALGO
# Fetches authorized_keys from a remote server and scans it.
scan_remote() {
    local host="$1" port="$2" user="$3" pq_key="$4" pq_algo="$5"
    local tmp_ak
    tmp_ak="$(mktemp)"
    trap 'rm -f "${tmp_ak}"' RETURN

    log_info "Fetching authorized_keys from ${user}@${host}:${port} ..."

    _ssh "${pq_key}" "${pq_algo}" \
        -p "${port}" "${user}@${host}" \
        "cat ~/.ssh/authorized_keys 2>/dev/null || echo ''" \
        > "${tmp_ak}" 2>/dev/null

    if [[ ! -s "${tmp_ak}" ]]; then
        log_warn "authorized_keys is empty or could not be read."
        return 2
    fi

    scan_authorized_keys "${tmp_ak}"
}

# ── Migration ────────────────────────────────────────────────────────────────

# migrate_classical_keys HOST PORT USER PQ_KEY PQ_ALGO
# For each classical key on the server, offer to remove it after confirming
# a PQ key is already authorised.
migrate_classical_keys() {
    local host="$1" port="$2" user="$3" pq_key="$4" pq_algo="$5"

    log_section "Migration Mode"
    log_info "This will remove classical keys from the server's authorized_keys."
    log_info "Your current PQ key (${pq_algo}) will be used for authentication."
    echo

    read -rp "Remove all classical keys from ${user}@${host}:${port}? (y/N): " do_migrate
    if [[ "${do_migrate}" != "y" && "${do_migrate}" != "Y" ]]; then
        log_info "Migration cancelled."
        return 0
    fi

    # Build a sed script that removes lines starting with classical prefixes.
    local filter_cmd='
        cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.pre_migration && \
        chmod 600 ~/.ssh/authorized_keys.pre_migration'
    for pattern in "${CLASSICAL_KEY_PATTERNS[@]}"; do
        filter_cmd="${filter_cmd} && "
        filter_cmd="${filter_cmd}grep -v \"^${pattern} \" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && "
        filter_cmd="${filter_cmd}mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys"
    done
    filter_cmd="${filter_cmd} && chmod 600 ~/.ssh/authorized_keys"
    filter_cmd="${filter_cmd} && echo MIGRATION_DONE"

    local result
    result="$(_ssh "${pq_key}" "${pq_algo}" \
        -p "${port}" "${user}@${host}" \
        "${filter_cmd}" 2>/dev/null || true)"

    if [[ "$result" == *"MIGRATION_DONE"* ]]; then
        log_success "Classical keys removed from server."
        log_info "A backup was saved on the server as ~/.ssh/authorized_keys.pre_migration"

        # Verify PQ key still works after migration
        if _ssh "${pq_key}" "${pq_algo}" \
                -p "${port}" "${user}@${host}" "echo PQ_OK" 2>/dev/null \
                | grep -q "PQ_OK"; then
            log_success "PQ key still authenticates after migration — success!"
        else
            log_error "PQ key authentication failed after migration!"
            log_error "Restore from backup: mv ~/.ssh/authorized_keys.pre_migration ~/.ssh/authorized_keys"
            return 1
        fi
    else
        log_error "Migration command did not complete successfully."
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    # Local-only mode
    if [[ "${1:-}" == "--local" ]]; then
        local local_ak="${SSH_DIR}/authorized_keys"
        if [[ -f "$local_ak" ]]; then
            scan_authorized_keys "$local_ak" || true
        else
            log_info "No local authorized_keys found at ${local_ak}"
        fi
        return 0
    fi

    require_oqs_build
    log_section "Post-Quantum Key Migration Tool"
    log_info "Scans for classical SSH keys and helps migrate them to PQ algorithms."
    echo

    read -rp "Server host/IP: " server_host
    validate_ip "$server_host" || exit 1

    read -rp "Server username: " server_user
    validate_username "$server_user" || exit 1

    read -rp "SSH port [22]: " server_port
    server_port="${server_port:-22}"
    validate_port "$server_port" || exit 1

    echo
    log_info "Select your current PQ algorithm (to authenticate with the server):"
    list_algorithms
    read -rp "Algorithm number: " algo_choice
    validate_algorithm_choice "$algo_choice" "${#ALGORITHMS[@]}" || exit 1
    local pq_algo="${ALGORITHMS[$((algo_choice-1))]}"
    local pq_key="${SSH_DIR}/id_${pq_algo}"
    validate_file_exists "$pq_key" || log_fatal "PQ key not found: ${pq_key}. Generate one first."

    # Phase 1: Scan
    local needs_migration=false
    if scan_remote "$server_host" "$server_port" "$server_user" "$pq_key" "$pq_algo"; then
        needs_migration=true
    fi

    # Phase 2: Migrate (if needed)
    if [[ "$needs_migration" == true ]]; then
        echo
        migrate_classical_keys "$server_host" "$server_port" "$server_user" "$pq_key" "$pq_algo"
    else
        log_success "No classical keys found — server is already fully post-quantum."
    fi

    # Also scan local authorized_keys
    local local_ak="${SSH_DIR}/authorized_keys"
    if [[ -f "$local_ak" ]]; then
        echo
        log_info "Also checking local ${local_ak} ..."
        scan_authorized_keys "$local_ak" || true
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
