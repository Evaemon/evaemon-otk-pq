#!/bin/bash
set -eo pipefail

# Post-quantum SSH key rotation tool.
#
# Workflow:
#   1. Generate a new PQ key pair (new algorithm or same type with fresh material)
#   2. Push the new public key to the remote server's authorized_keys
#   3. Verify the new key authenticates successfully
#   4. Optionally remove the old key from the server's authorized_keys
#   5. Archive the old key locally with a timestamp suffix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# check_key_age KEY_FILE
# Returns 0 if the key is older than KEY_MAX_AGE_DAYS (default 90), 1 otherwise.
# Prints a warning with the exact age if overdue.
check_key_age() {
    local key_file="$1"
    [[ -f "$key_file" ]] || return 1

    local max_age="${KEY_MAX_AGE_DAYS:-90}"
    local now key_mtime age_days
    now="$(date +%s)"
    key_mtime="$(stat -c "%Y" "$key_file" 2>/dev/null || echo "$now")"
    age_days="$(( (now - key_mtime) / 86400 ))"

    if (( age_days >= max_age )); then
        log_warn "Key ${key_file} is ${age_days} days old (max ${max_age}). Rotation is overdue."
        return 0
    else
        log_info "Key ${key_file} is ${age_days} days old (max ${max_age}). Within policy."
        return 1
    fi
}

# verify_old_key_invalidated HOST PORT USER OLD_KEY OLD_ALGO
# After rotation, confirm the old key can no longer authenticate.
# This is the critical safety check: rotation is not complete until the
# old credential is provably dead.
verify_old_key_invalidated() {
    local host="$1" port="$2" user="$3" old_key="$4" old_algo="$5"

    [[ -f "$old_key" ]] || { log_info "Old key file not present — nothing to verify."; return 0; }

    log_section "Verifying Old Key Is Invalidated"

    if _ssh "${old_key}" "${old_algo}" \
            -p "${port}" "${user}@${host}" "echo STILL_ALIVE" 2>/dev/null \
            | grep -q "STILL_ALIVE"; then
        log_error "OLD KEY STILL AUTHENTICATES! The server still accepts ${old_key}."
        log_error "Remove it from the server's authorized_keys before considering rotation complete."
        return 1
    fi

    log_success "Old key correctly rejected — rotation verified."
    return 0
}

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

# ── Steps ────────────────────────────────────────────────────────────────────

generate_new_key() {
    local key_type="$1"
    local key_file="${SSH_DIR}/id_${key_type}"

    if [[ -f "${key_file}" || -f "${key_file}.pub" ]]; then
        log_warn "Key already exists: ${key_file}"
        log_info "It will be archived before the new key is written."
    fi

    log_section "Generating New Key"

    read -rp "Protect the new key with a passphrase? (y/N): " use_pass
    if [[ "${use_pass}" == "y" || "${use_pass}" == "Y" ]]; then
        "${BIN_DIR}/ssh-keygen" -t "${key_type}" -f "${key_file}"
    else
        "${BIN_DIR}/ssh-keygen" -t "${key_type}" -f "${key_file}" -N ""
    fi

    chmod 600 "${key_file}"
    chmod 644 "${key_file}.pub"
    log_info "New key written to ${key_file}"
}

push_new_key() {
    local host="$1" port="$2" user="$3"
    local new_algo="$4"
    local old_key="$5"
    local old_algo="$6"
    local new_pub="${SSH_DIR}/id_${new_algo}.pub"

    log_section "Pushing New Public Key to Server"
    validate_file_exists "$new_pub" || exit 1

    _ssh "${old_key}" "${old_algo}" \
        -p "${port}" "${user}@${host}" \
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
         key=$(cat) && \
         if grep -qF "$key" ~/.ssh/authorized_keys 2>/dev/null; then \
             echo "Key already present."; \
         else \
             printf "%s\n" "$key" >> ~/.ssh/authorized_keys && \
             echo "Key added."; \
         fi' \
        < "${new_pub}"

    log_info "New public key added to ${user}@${host}:~/.ssh/authorized_keys"
}

verify_new_key() {
    local host="$1" port="$2" user="$3" new_algo="$4"
    local new_key="${SSH_DIR}/id_${new_algo}"
    log_section "Verifying New Key"

    # The server may need a moment to register the newly-pushed key;
    # retry up to 4 times with exponential backoff (2s → 4s → 8s → 16s).
    local attempt=1 delay=2
    while (( attempt <= 4 )); do
        if _ssh "${new_key}" "${new_algo}" \
                -p "${port}" "${user}@${host}" "echo ROTATION_OK" 2>/dev/null \
                | grep -q "ROTATION_OK"; then
            log_success "New key authenticates successfully."
            return
        fi
        if (( attempt < 4 )); then
            log_warn "Verification attempt ${attempt}/4 failed -- retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    log_fatal "New key verification FAILED -- old key has NOT been removed. Investigate before retrying."
}

remove_old_key_from_server() {
    local host="$1" port="$2" user="$3"
    local new_algo="$4" new_key="${SSH_DIR}/id_${new_algo}"
    local old_pub="$5"

    log_section "Removing Old Public Key from Server"
    if [[ ! -f "$old_pub" ]]; then
        log_warn "Old public key not found locally -- skipping server removal."
        return
    fi

    # Pass the key content via stdin to avoid shell injection from key comments.
    _ssh "${new_key}" "${new_algo}" \
        -p "${port}" "${user}@${host}" \
        'IFS= read -r OLD_KEY
         grep -vF "${OLD_KEY}" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && \
         mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys && \
         echo "Old key removed from authorized_keys."' \
        < "$old_pub"

    log_info "Old key removed from server."
}

archive_old_key() {
    local key_file="$1"
    local ts
    ts="$(date "+%Y%m%d_%H%M%S")"

    for ext in "" ".pub"; do
        local src="${key_file}${ext}"
        if [[ -f "$src" ]]; then
            local dest="${src}.retired_${ts}"
            mv "$src" "$dest"
            chmod 400 "$dest"
            log_info "Archived: ${src} -> ${dest}"
        fi
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_oqs_build
    log_section "Post-Quantum SSH Key Rotation"

    read -rp "Server host/IP: " server_host
    validate_ip "$server_host" || exit 1

    read -rp "Server username: " server_user
    validate_username "$server_user" || exit 1

    read -rp "SSH port [22]: " server_port
    server_port="${server_port:-22}"
    validate_port "$server_port" || exit 1

    echo
    log_info "Select the CURRENT algorithm (used to reach the server now):"
    list_algorithms
    read -rp "Current algorithm number: " old_choice
    validate_algorithm_choice "$old_choice" "${#ALGORITHMS[@]}" || exit 1
    local old_algo="${ALGORITHMS[$((old_choice-1))]}"
    local old_key="${SSH_DIR}/id_${old_algo}"
    local old_pub="${old_key}.pub"
    validate_file_exists "$old_key" || log_fatal "Current private key not found: ${old_key}"

    # ── 90-day rotation policy check ─────────────────────────────────────
    if check_key_age "$old_key"; then
        log_warn "Key rotation is OVERDUE per the ${KEY_MAX_AGE_DAYS}-day policy."
    else
        read -rp "Key is still within rotation policy. Continue anyway? (y/N): " force_rotate
        if [[ "${force_rotate}" != "y" && "${force_rotate}" != "Y" ]]; then
            log_info "Rotation cancelled. Current key is still within the ${KEY_MAX_AGE_DAYS}-day window."
            return 0
        fi
    fi

    echo
    log_info "Select the NEW algorithm for the rotated key:"
    list_algorithms
    read -rp "New algorithm number: " new_choice
    validate_algorithm_choice "$new_choice" "${#ALGORITHMS[@]}" || exit 1
    local new_algo="${ALGORITHMS[$((new_choice-1))]}"

    # When rotating to the same algorithm, archive the old key first so we
    # can still use it as the bootstrap credential.
    if [[ "$old_algo" == "$new_algo" ]]; then
        log_warn "Old and new algorithms are the same (${old_algo}). Archiving old key before generating new one."
        archive_old_key "$old_key"
        # Find the just-archived key to use as bootstrap.
        # Sort by the YYYYMMDD_HHMMSS timestamp suffix in the filename
        # (lexicographic == chronological for this format) instead of using
        # `ls -t`, which parses mtime and is unsafe with unusual filenames.
        old_key="$(find "${SSH_DIR}" -maxdepth 1 \
            -name "id_${old_algo}.retired_*" ! -name "*.pub" -print 2>/dev/null \
            | sort -r | head -1)"
        if [[ -z "$old_key" ]]; then
            log_fatal "Could not locate the archived ${old_algo} key in ${SSH_DIR}. Cannot continue rotation."
        fi
        old_pub="${old_key%.retired_*}.pub.retired_${old_key##*.retired_}"
    fi

    generate_new_key   "$new_algo"
    push_new_key       "$server_host" "$server_port" "$server_user" "$new_algo" "$old_key" "$old_algo"
    verify_new_key     "$server_host" "$server_port" "$server_user" "$new_algo"

    read -rp "Remove old key from server's authorized_keys? (y/N): " remove_old
    if [[ "${remove_old}" == "y" || "${remove_old}" == "Y" ]]; then
        remove_old_key_from_server "$server_host" "$server_port" "$server_user" "$new_algo" "$old_pub"

        # Verify the old key is truly invalidated on the server.
        verify_old_key_invalidated "$server_host" "$server_port" "$server_user" "$old_key" "$old_algo" \
            || log_warn "Post-rotation validation failed — old key may still be active. Investigate."
    else
        log_warn "Old key left on server. Remove it manually when you are confident the new key works."
    fi

    # Archive old key if it hasn't been already (different-algorithm rotation)
    if [[ -f "${SSH_DIR}/id_${old_algo}" ]]; then
        archive_old_key "${SSH_DIR}/id_${old_algo}"
    fi

    log_section "Key Rotation Complete"
    log_success "New key: ${SSH_DIR}/id_${new_algo}"
    log_info    "Server:  ${server_user}@${server_host}:${server_port}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
