#!/bin/bash
set -eo pipefail

# OTK-PQ Server — Session Verification & Master Key Enrollment
#
# Server-side component of the OTK-PQ architecture.  Handles:
#   - Master public key enrollment (one-time, per client)
#   - Session bundle verification (every connection)
#   - Revocation ledger integration
#   - OTK-aware sshd configuration
#
# The server ONLY holds master PUBLIC keys — never master private keys.
# If the server is compromised, the attacker cannot forge session keys
# because they lack the client's master private key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/otk_config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"
source "${SCRIPT_DIR}/revocation_ledger.sh"

# ── Directory Setup ──────────────────────────────────────────────────────────

_ensure_server_otk_dirs() {
    if [[ ! -d "${OTK_SERVER_ENROLLED_DIR}" ]]; then
        mkdir -p "${OTK_SERVER_ENROLLED_DIR}"
        chmod "${OTK_DIR_PERMS}" "${OTK_SERVER_ENROLLED_DIR}"
        # Ensure parent directories also have correct permissions
        local parent
        parent="$(dirname "${OTK_SERVER_ENROLLED_DIR}")"
        chmod "${OTK_DIR_PERMS}" "${parent}" 2>/dev/null || true
        log_debug "Created OTK enrollment directory: ${OTK_SERVER_ENROLLED_DIR}"
    fi

    init_ledger
}

# ── Master Key Enrollment ────────────────────────────────────────────────────

# enroll_master_key CLIENT_NAME [PUBLIC_KEY_FILE]
# Register a client's master public key on the server.
# The public key is stored in OTK_SERVER_ENROLLED_DIR/<client_name>.pub
# If PUBLIC_KEY_FILE is not given, reads from stdin (for piped enrollment).
# Returns 0 on success, 1 if the key file is not a valid SSH public key.
enroll_master_key() {
    local client_name="${1:-}"
    local pub_key_file="${2:-}"

    _ensure_server_otk_dirs

    if [[ -z "${client_name}" ]]; then
        read -rp "Enter client name (unique identifier): " client_name
    fi

    # Validate client name (POSIX-safe)
    if [[ ! "${client_name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_fatal "Invalid client name: must be alphanumeric, dots, underscores, hyphens only"
    fi

    local enrolled_path="${OTK_SERVER_ENROLLED_DIR}/${client_name}.pub"

    if [[ -f "${enrolled_path}" ]]; then
        log_warn "Client '${client_name}' is already enrolled."
        read -rp "Replace existing enrollment? (y/N): " replace
        if [[ "${replace}" != "y" && "${replace}" != "Y" ]]; then
            log_info "Enrollment unchanged."
            return 0
        fi
        # Archive old enrollment
        mv "${enrolled_path}" "${enrolled_path}.old.$(date +%s)"
        log_info "Archived previous enrollment"
    fi

    if [[ -n "${pub_key_file}" && -f "${pub_key_file}" ]]; then
        cp "${pub_key_file}" "${enrolled_path}"
    else
        log_info "Paste the client's master public key (then press Ctrl-D):"
        cat > "${enrolled_path}"
    fi

    chmod "${OTK_PUBLIC_KEY_PERMS}" "${enrolled_path}"

    # Validate that the file contains a valid SSH public key
    # This prevents storing corrupt or malicious files as enrolled keys
    if [[ -x "${BIN_DIR}/ssh-keygen" ]]; then
        local fingerprint
        fingerprint="$("${BIN_DIR}/ssh-keygen" -l -f "${enrolled_path}" 2>/dev/null || true)"
        if [[ -z "${fingerprint}" ]]; then
            log_error "Invalid public key: file is not a valid SSH public key"
            rm -f "${enrolled_path}"
            return 1
        fi

        # Verify the key type matches the expected OTK master key algorithm
        local key_type
        key_type="$(awk '{print $1}' "${enrolled_path}" 2>/dev/null || true)"
        if [[ -n "${OTK_MASTER_SIGN_ALGO}" && "${key_type}" != "${OTK_MASTER_SIGN_ALGO}" ]]; then
            log_warn "Key type mismatch: expected '${OTK_MASTER_SIGN_ALGO}', got '${key_type}'"
            log_warn "Proceeding with enrollment — ensure this is intentional"
        fi

        log_success "Enrolled client '${client_name}': ${fingerprint}"
    else
        # Without ssh-keygen, do a basic format check (key should have at least 2 fields)
        local field_count
        field_count="$(awk '{print NF}' "${enrolled_path}" 2>/dev/null | head -1)"
        if [[ -z "${field_count}" ]] || (( field_count < 2 )); then
            log_error "Invalid public key: file does not appear to be a valid SSH public key"
            rm -f "${enrolled_path}"
            return 1
        fi
        log_success "Enrolled client '${client_name}' (key format not fully verified — ssh-keygen unavailable)"
    fi

    log_info "Enrolled key stored at: ${enrolled_path}"
}

# list_enrolled
# Show all enrolled client master public keys.
# Returns 0 always.
list_enrolled() {
    _ensure_server_otk_dirs

    log_section "OTK-PQ Enrolled Clients"

    local count=0
    for pub_file in "${OTK_SERVER_ENROLLED_DIR}"/*.pub; do
        [[ -f "${pub_file}" ]] || continue
        local client_name
        client_name="$(basename "${pub_file}" .pub)"

        local fingerprint="unknown"
        if [[ -x "${BIN_DIR}/ssh-keygen" ]]; then
            fingerprint="$("${BIN_DIR}/ssh-keygen" -l -f "${pub_file}" 2>/dev/null || echo "unreadable")"
        fi

        log_info "  ${client_name}: ${fingerprint}"
        (( count++ )) || true
    done

    if (( count == 0 )); then
        log_info "No clients enrolled."
        log_info "Enroll with: bash server/otk/otk_server.sh enroll <client_name> <pubkey_file>"
    else
        log_info ""
        log_info "${count} client(s) enrolled"
    fi
}

# revoke_client CLIENT_NAME
# Remove a client's enrollment (reject all future sessions from this client).
# Returns 0 on success, 1 if the client is not enrolled.
revoke_client() {
    local client_name="${1:-}"

    if [[ -z "${client_name}" ]]; then
        log_fatal "Usage: revoke <client_name>"
    fi

    local enrolled_path="${OTK_SERVER_ENROLLED_DIR}/${client_name}.pub"

    if [[ ! -f "${enrolled_path}" ]]; then
        log_error "Client '${client_name}' is not enrolled"
        return 1
    fi

    rm -f "${enrolled_path}"
    log_success "Client '${client_name}' enrollment revoked"
    log_info "All future sessions from this client will be rejected"
}

# ── Session Verification ────────────────────────────────────────────────────

# verify_session_bundle BUNDLE_EXPORT_DIR CLIENT_NAME
# Perform the full OTK-PQ server-side verification:
#   1. Check revocation ledger — has this session key been used before?
#   2. Verify master key signature — is the session key legitimately signed?
#   3. Validate nonce — is the timestamp acceptable? Is the random unique?
#   4. If all pass — accept the session
#
# Returns 0 on success, 1 on failure.
verify_session_bundle() {
    local export_dir="$1"
    local client_name="${2:-}"

    _ensure_server_otk_dirs

    log_debug "Verifying session bundle: ${export_dir}"

    # ── Validate bundle contents ──
    local required_files=("session_key.pub" "session_pq_key.pub" "master_signature" "nonce" "session_id")
    for f in "${required_files[@]}"; do
        if [[ ! -f "${export_dir}/${f}" ]]; then
            log_error "Session bundle missing required file: ${f}"
            return 1
        fi
    done

    # Validate that public key files contain properly formatted SSH keys
    for key_file in "session_key.pub" "session_pq_key.pub"; do
        local key_content
        key_content="$(cat "${export_dir}/${key_file}")"
        # SSH public keys must have at least 2 space-separated fields: type and base64 data
        if [[ -z "${key_content}" ]] || (( $(echo "${key_content}" | awk '{print NF}') < 2 )); then
            log_error "Invalid session key format in ${key_file}: expected 'type base64data [comment]'"
            return 1
        fi
        # Key type must start with ssh- or ecdsa- (covers ssh-ed25519, ssh-mldsa87, ecdsa-*, etc.)
        local key_type="${key_content%% *}"
        if [[ ! "${key_type}" =~ ^(ssh-|ecdsa-) ]]; then
            log_error "Unrecognized key type '${key_type}' in ${key_file}"
            return 1
        fi
    done

    local session_id
    session_id="$(cat "${export_dir}/session_id")"
    local nonce
    nonce="$(cat "${export_dir}/nonce")"

    log_debug "Session ID: ${session_id:0:16}..."

    # ── Step 1: Check revocation ledger ──
    if ledger_check "${session_id}"; then
        log_error "REPLAY ATTACK DETECTED: Session ${session_id:0:16}... already used"
        return 1
    fi

    # ── Step 2: Validate nonce ──
    # Source session_key.sh for validate_nonce (reuse the function)
    local nonce_timestamp="${nonce%%:*}"
    local current_ts
    current_ts="$(date +%s)"
    local nonce_age=$(( current_ts - nonce_timestamp ))

    if [[ ! "${nonce_timestamp}" =~ ^[0-9]+$ ]]; then
        log_error "Malformed nonce: timestamp is not a number"
        return 1
    fi

    if (( nonce_age < 0 )); then
        local skew=$(( -nonce_age ))
        log_error "Clock skew detected: client clock is ${skew}s ahead of server"
        log_error "Sync clocks with NTP or increase OTK_NONCE_MAX_AGE (current: ${OTK_NONCE_MAX_AGE}s)"
        return 1
    fi

    if (( nonce_age > OTK_NONCE_MAX_AGE )); then
        log_error "Session nonce expired: age=${nonce_age}s exceeds max=${OTK_NONCE_MAX_AGE}s"
        if (( nonce_age > 3600 )); then
            log_error "Clock skew detected: client clock is ${nonce_age}s behind server — sync with NTP"
        fi
        return 1
    fi

    log_debug "Nonce valid: age=${nonce_age}s"

    # ── Step 3: Verify master key signature ──
    if [[ -z "${client_name}" ]]; then
        # Try to identify client by checking all enrolled keys
        client_name="$(_identify_client "${export_dir}")"
        if [[ -z "${client_name}" ]]; then
            log_error "Cannot identify client — no enrolled key matches the signature"
            return 1
        fi
    fi

    local enrolled_pub="${OTK_SERVER_ENROLLED_DIR}/${client_name}.pub"
    if [[ ! -f "${enrolled_pub}" ]]; then
        log_error "Client '${client_name}' is not enrolled"
        return 1
    fi

    # Reconstruct the signed data: nonce + classical pub + PQ pub
    local verify_data="${export_dir}/.verify_data"
    {
        cat "${export_dir}/nonce"
        cat "${export_dir}/session_key.pub"
        cat "${export_dir}/session_pq_key.pub"
    } > "${verify_data}"

    # Create allowed signers file for ssh-keygen -Y verify
    local allowed_signers="${export_dir}/.allowed_signers"
    echo "${client_name} $(cat "${enrolled_pub}")" > "${allowed_signers}"

    # Verify the signature
    local verify_result
    if "${BIN_DIR}/ssh-keygen" \
        -Y verify \
        -f "${allowed_signers}" \
        -I "${client_name}" \
        -n "otk-session" \
        -s "${export_dir}/master_signature" \
        < "${verify_data}" 2>/dev/null; then
        log_debug "Master key signature verified for client '${client_name}'"
    else
        log_error "SIGNATURE VERIFICATION FAILED for client '${client_name}'"
        rm -f "${verify_data}" "${allowed_signers}"
        return 1
    fi

    rm -f "${verify_data}" "${allowed_signers}"

    # ── Step 4: All checks passed — add to revocation ledger ──
    ledger_add "${session_id}"
    log_debug "Session ${session_id:0:16}... added to revocation ledger"

    log_success "Session bundle verified for client '${client_name}'"
    return 0
}

# _identify_client EXPORT_DIR
# Try to identify which enrolled client created the session bundle
# by checking the master signature against all enrolled public keys.
# Prints the client name to stdout and returns 0 if found; returns 1 if no match.
_identify_client() {
    local export_dir="$1"

    # Reconstruct signed data
    local verify_data="${export_dir}/.verify_data_check"
    {
        cat "${export_dir}/nonce"
        cat "${export_dir}/session_key.pub"
        cat "${export_dir}/session_pq_key.pub"
    } > "${verify_data}"

    for pub_file in "${OTK_SERVER_ENROLLED_DIR}"/*.pub; do
        [[ -f "${pub_file}" ]] || continue
        local name
        name="$(basename "${pub_file}" .pub)"

        local allowed_signers="${export_dir}/.allowed_signers_check"
        echo "${name} $(cat "${pub_file}")" > "${allowed_signers}"

        if "${BIN_DIR}/ssh-keygen" \
            -Y verify \
            -f "${allowed_signers}" \
            -I "${name}" \
            -n "otk-session" \
            -s "${export_dir}/master_signature" \
            < "${verify_data}" 2>/dev/null; then
            rm -f "${verify_data}" "${allowed_signers}"
            echo "${name}"
            return 0
        fi

        rm -f "${allowed_signers}"
    done

    rm -f "${verify_data}"
    return 1
}

# ── OTK Server Setup ────────────────────────────────────────────────────────

# setup_otk_server
# Configure the server for OTK-PQ mode alongside standard PQ SSH.
# Returns 0 on success.
setup_otk_server() {
    _ensure_server_otk_dirs

    log_section "OTK-PQ Server Setup"

    # Initialize revocation ledger
    init_ledger
    log_success "Revocation ledger initialized"

    # Create enrollment directory
    log_success "Enrollment directory ready: ${OTK_SERVER_ENROLLED_DIR}"

    log_info ""
    log_info "OTK-PQ server is ready."
    log_info ""
    log_info "Next steps:"
    log_info "  1. Enroll client master keys:"
    log_info "     bash server/otk/otk_server.sh enroll <client_name> <pubkey_file>"
    log_info ""
    log_info "  2. Clients can then connect using OTK mode:"
    log_info "     bash client/otk/otk_connect.sh <server_host>"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"

    case "${command}" in
        setup)
            setup_otk_server
            ;;
        enroll)
            shift
            enroll_master_key "$@"
            ;;
        list)
            list_enrolled
            ;;
        revoke)
            revoke_client "${2:-}"
            ;;
        verify)
            shift
            verify_session_bundle "$@"
            ;;
        ledger)
            shift
            # Delegate to revocation_ledger.sh
            case "${1:-}" in
                stats)  ledger_stats ;;
                prune)  ledger_prune ;;
                *)      echo "Usage: $(basename "$0") ledger {stats|prune}" ;;
            esac
            ;;
        *)
            echo "OTK-PQ Server — Session Verification & Enrollment"
            echo "──────────────────────────────────────────────────"
            echo
            echo "Usage: $(basename "$0") <command>"
            echo
            echo "Commands:"
            echo "  setup                           Initialize OTK-PQ server"
            echo "  enroll <name> [pubkey_file]      Enroll a client's master public key"
            echo "  list                             List enrolled clients"
            echo "  revoke <name>                    Revoke a client's enrollment"
            echo "  verify <bundle_dir> [client]     Verify a session bundle"
            echo "  ledger stats                     Show revocation ledger statistics"
            echo "  ledger prune                     Prune expired ledger entries"
            echo
            echo "The server only holds master PUBLIC keys — never private keys."
            echo "If the server is compromised, attackers cannot forge sessions."
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
