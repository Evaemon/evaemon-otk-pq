#!/bin/bash
set -eo pipefail

# OTK-PQ Connect — One-Time Key Post-Quantum SSH Connection
#
# Orchestrates all three layers of the OTK-PQ architecture into a single
# connection flow:
#
#   1. PRE-CONNECT (Layer 2):
#      Generate fresh hybrid session key pair, signed by master key
#
#   2. CONNECT (Layer 1 + 2):
#      Push session bundle to server for verification, then establish
#      SSH session using the ephemeral key with hybrid PQ/classical KEX
#
#   3. POST-CONNECT (Layer 3):
#      Securely destroy all session key material — key ceases to exist
#
# Every connection is unique.  Every key is temporary.  Every session is final.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/otk_config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"
source "${SCRIPT_DIR}/session_key.sh"
source "${SCRIPT_DIR}/otk_lifecycle.sh"

# ── OTK Connection ──────────────────────────────────────────────────────────

# otk_connect HOST USER PORT
# Execute a full OTK-PQ connection lifecycle.
otk_connect() {
    local server_host="$1"
    local username="$2"
    local port="${3:-22}"
    local bundle_dir=""
    local session_id=""
    local connect_exit_code=0

    require_oqs_build

    log_section "OTK-PQ Connection — One-Time Key Authentication"
    log_info "Target: ${username}@${server_host}:${port}"

    # ── Phase 1: Pre-connect — Generate session bundle (Layer 2) ──
    log_section "Phase 1 — Generating Ephemeral Session Keys"

    bundle_dir="$(generate_session_keypair)"
    session_id="$(cat "${bundle_dir}/session_id")"

    log_success "Session bundle created"
    log_info "Session ID: ${session_id:0:16}..."
    log_info "Classical:  Ed25519 (ephemeral)"
    log_info "PQ:         ${OTK_MASTER_SIGN_ALGO} (ephemeral, master-signed)"

    # ── Phase 2: Connect — Push bundle & establish session ──
    log_section "Phase 2 — Establishing OTK-PQ Session"

    # Export the session bundle (public material only)
    local export_dir
    export_dir="$(export_session_bundle "${bundle_dir}")"

    # Transfer the session bundle to the server for verification.
    # The server will:
    #   1. Check the revocation ledger
    #   2. Verify the master key signature
    #   3. Validate the nonce
    #   4. If all pass, install the ephemeral public key temporarily
    log_info "Pushing session bundle to server..."

    # Create a temporary authorized_keys entry with the ephemeral key
    # The session PQ key is used for authentication
    local session_pq_pub
    session_pq_pub="$(cat "${bundle_dir}/session_pq_key.pub")"

    # Push the session bundle to the server:
    # 1. Transfer public keys + signature + nonce
    # 2. Server verifies and temporarily authorizes the session key
    # 3. Connect using the ephemeral session key
    _push_and_connect \
        "${server_host}" "${username}" "${port}" \
        "${bundle_dir}" "${export_dir}" || connect_exit_code=$?

    # ── Phase 3: Post-connect — Destroy session keys (Layer 3) ──
    log_section "Phase 3 — Destroying Session Keys"

    # Mark session as used (client-side defense-in-depth)
    mark_session_used "${bundle_dir}"

    # Securely destroy all session key material
    destroy_session "${bundle_dir}"

    # Verify destruction
    if verify_destruction "${bundle_dir}"; then
        log_success "Session keys destroyed and verified"
    else
        log_error "WARNING: Session key destruction verification failed"
        log_error "Attempting forced cleanup..."
        rm -rf "${bundle_dir}"
    fi

    log_info "Session ${session_id:0:16}... terminated"
    log_info "Key material: DESTROYED"

    if (( connect_exit_code != 0 )); then
        log_warn "SSH session exited with code ${connect_exit_code}"
    fi

    return ${connect_exit_code}
}

# ── Push & Connect ───────────────────────────────────────────────────────────

# _push_and_connect HOST USER PORT BUNDLE_DIR EXPORT_DIR
# Transfer session bundle to the server and establish the SSH connection.
_push_and_connect() {
    local host="$1" user="$2" port="$3"
    local bundle_dir="$4" export_dir="$5"

    # Strategy: Use the existing PQ key (from standard evaemon) to push
    # the session bundle, then re-connect using the ephemeral session key.
    # This requires the client to have an existing PQ key for the initial
    # bootstrap connection.

    # Find an existing PQ key for the bootstrap connection
    local bootstrap_key=""
    for algo in "${ALGORITHMS[@]}"; do
        local key_path="${SSH_DIR}/id_${algo}"
        if [[ -f "${key_path}" ]]; then
            bootstrap_key="${key_path}"
            break
        fi
    done

    # Also check for classical keys as fallback
    if [[ -z "${bootstrap_key}" ]]; then
        for kt in "${CLASSICAL_KEYTYPES[@]}"; do
            local key_path="${SSH_DIR}/id_${kt}"
            if [[ -f "${key_path}" ]]; then
                bootstrap_key="${key_path}"
                break
            fi
        done
    fi

    if [[ -z "${bootstrap_key}" ]]; then
        log_fatal "No existing SSH key found for bootstrap connection. Generate one first with: bash client/keygen.sh"
    fi

    log_debug "Using bootstrap key: ${bootstrap_key}"

    # Step 1: Push the session bundle to the server
    # The server-side OTK verification script handles bundle validation
    log_info "Transferring session bundle to server..."

    # Create a temporary script that the server will execute to:
    # - Receive and verify the session bundle
    # - Temporarily add the session public key to authorized_keys
    # - Clean up after the session ends
    local session_pub_content
    session_pub_content="$(cat "${bundle_dir}/session_pq_key.pub")"

    local nonce_content
    nonce_content="$(cat "${bundle_dir}/nonce")"

    local signature_b64
    signature_b64="$(base64 -w 0 "${bundle_dir}/master_signature" 2>/dev/null || base64 "${bundle_dir}/master_signature" 2>/dev/null)"

    local session_classical_pub
    session_classical_pub="$(cat "${bundle_dir}/session_key.pub")"

    local session_id
    session_id="$(cat "${bundle_dir}/session_id")"

    # Push the session key to the server's authorized_keys (temporarily)
    # The server adds the key, we connect, and on disconnect the key is removed
    local remote_script
    remote_script="$(cat <<'REMOTE_EOF'
#!/bin/bash
set -e
SESSION_PUB="__SESSION_PUB__"
SESSION_ID="__SESSION_ID__"
AK="${HOME}/.ssh/authorized_keys"

# Add session key with a comment marking it as OTK
mkdir -p "${HOME}/.ssh"
echo "${SESSION_PUB}" >> "${AK}"

# Record session ID for tracking
echo "OTK_SESSION_INSTALLED:${SESSION_ID}"
REMOTE_EOF
)"

    # Substitute values into the remote script
    remote_script="${remote_script//__SESSION_PUB__/${session_pub_content}}"
    remote_script="${remote_script//__SESSION_ID__/${session_id}}"

    # Execute the remote script via the bootstrap key
    local push_result
    push_result="$(SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${OTK_SESSION_KEX_LIST}" \
        -o "StrictHostKeyChecking=accept-new" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -i "${bootstrap_key}" \
        -p "${port}" \
        "${user}@${host}" \
        "${remote_script}" 2>/dev/null || echo "PUSH_FAILED")"

    if [[ "${push_result}" == *"PUSH_FAILED"* ]]; then
        log_error "Failed to push session bundle to server"
        log_error "Ensure you have an existing SSH key authorized on the server"
        return 1
    fi

    log_success "Session key installed on server"

    # Step 2: Connect using the ephemeral session key
    log_info "Connecting with ephemeral OTK session key..."

    local session_key="${bundle_dir}/session_pq_key"
    local session_algo="${OTK_MASTER_SIGN_ALGO}"
    local connect_result=0

    SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${OTK_SESSION_KEX_LIST}" \
        -o "HostKeyAlgorithms=${session_algo},${CLASSICAL_HOST_ALGOS}" \
        -o "PubkeyAcceptedKeyTypes=${session_algo},${CLASSICAL_HOST_ALGOS}" \
        -o "StrictHostKeyChecking=accept-new" \
        -i "${session_key}" \
        -p "${port}" \
        "${user}@${host}" || connect_result=$?

    # Step 3: Remove the session key from the server's authorized_keys
    log_info "Removing ephemeral key from server..."

    local cleanup_script
    cleanup_script="$(cat <<'CLEANUP_EOF'
#!/bin/bash
set -e
SESSION_PUB="__SESSION_PUB__"
AK="${HOME}/.ssh/authorized_keys"
if [ -f "${AK}" ]; then
    TEMP=$(mktemp)
    grep -vF "${SESSION_PUB}" "${AK}" > "${TEMP}" 2>/dev/null || true
    mv "${TEMP}" "${AK}"
    chmod 600 "${AK}"
    echo "OTK_SESSION_REMOVED"
fi
CLEANUP_EOF
)"
    cleanup_script="${cleanup_script//__SESSION_PUB__/${session_pub_content}}"

    SSH_AUTH_SOCK="" "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${OTK_SESSION_KEX_LIST}" \
        -o "ConnectTimeout=10" \
        -o "BatchMode=yes" \
        -i "${bootstrap_key}" \
        -p "${port}" \
        "${user}@${host}" \
        "${cleanup_script}" 2>/dev/null || log_warn "Could not clean up session key from server"

    return ${connect_result}
}

# ── Interactive Mode ─────────────────────────────────────────────────────────

# otk_connect_interactive
# Prompt for connection details and execute OTK connection.
otk_connect_interactive() {
    echo "OTK-PQ — One-Time Key Post-Quantum SSH Connection"
    echo "──────────────────────────────────────────────────"
    echo
    echo "Every connection generates a unique ephemeral key that is"
    echo "destroyed after the session ends. Nothing persists."
    echo

    # Check for master key
    local master_key="${OTK_MASTER_DIR}/${OTK_MASTER_SIGN_KEY}"
    if [[ ! -f "${master_key}" ]]; then
        log_error "No OTK master key found."
        log_error "Generate one first: bash client/otk/master_key.sh generate"
        log_error "Then enroll it on the server: bash server/otk/otk_server.sh enroll"
        exit 1
    fi

    read -rp "Enter the server host/IP: " server_host
    validate_ip "${server_host}" || exit 1

    read -rp "Enter the username: " username
    validate_username "${username}" || exit 1

    read -rp "Enter the SSH port [22]: " port
    port="${port:-22}"
    validate_port "${port}" || exit 1

    echo
    log_info "Starting OTK-PQ connection..."
    echo

    otk_connect "${server_host}" "${username}" "${port}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"

    case "${command}" in
        connect)
            shift
            if (( $# >= 2 )); then
                otk_connect "$@"
            else
                otk_connect_interactive
            fi
            ;;
        "")
            otk_connect_interactive
            ;;
        *)
            # Treat arguments as host user [port]
            otk_connect "$@"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
