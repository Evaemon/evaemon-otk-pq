#!/bin/bash
set -eo pipefail

# OTK-PQ Layer 3 — One-Time Execution & Destruction
#
# Manages the lifecycle of ephemeral session keys:
#   1. Enforces one-time use — a session key can only be used for a single connection
#   2. Destroys key material — cryptographic invalidation after session ends
#   3. Verifies destruction — confirms no residual key material remains
#
# "Destruction is a feature" — the system is designed around the assumption
# that every key will be destroyed.  The question is only whether the session
# completes first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/otk_config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"

# ── Secure Destruction ───────────────────────────────────────────────────────

# _secure_delete FILE
# Overwrite a file with random data before unlinking.
# Uses shred if available, falls back to manual overwrite.
_secure_delete() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        return 0
    fi

    if command -v shred &>/dev/null; then
        shred -u -z -n "${OTK_SHRED_PASSES}" "${file}" 2>/dev/null || rm -f "${file}"
    else
        # Manual overwrite: write random bytes, then zeros, then remove
        local file_size
        file_size="$(wc -c < "${file}" 2>/dev/null || echo 0)"
        if (( file_size > 0 )); then
            local pass
            for (( pass=0; pass < OTK_SHRED_PASSES; pass++ )); do
                if ! dd if=/dev/urandom of="${file}" bs=1 count="${file_size}" conv=notrunc 2>/dev/null; then
                    log_warn "Secure overwrite failed (pass $((pass+1))) for ${file} — disk full or I/O error"
                    break
                fi
            done
            dd if=/dev/zero of="${file}" bs=1 count="${file_size}" conv=notrunc 2>/dev/null || \
                log_warn "Zero-pass overwrite failed for ${file} — disk full or I/O error"
        fi
        rm -f "${file}"
    fi
}

# ── Session Key Destruction ──────────────────────────────────────────────────

# destroy_session BUNDLE_DIR
# Securely destroy all key material in a session bundle.
# This is the core Layer 3 operation — after this, the session key
# ceases to exist and cannot be reconstructed.
destroy_session() {
    local bundle_dir="$1"

    if [[ ! -d "${bundle_dir}" ]]; then
        log_warn "Session bundle not found: ${bundle_dir} (may already be destroyed)"
        return 0
    fi

    local session_id="unknown"
    [[ -f "${bundle_dir}/session_id" ]] && session_id="$(cat "${bundle_dir}/session_id")"

    log_debug "Destroying session bundle: ${session_id:0:16}..."

    # Destroy private keys first (most sensitive)
    _secure_delete "${bundle_dir}/session_key"
    _secure_delete "${bundle_dir}/session_pq_key"

    # Destroy public keys
    _secure_delete "${bundle_dir}/session_key.pub"
    _secure_delete "${bundle_dir}/session_pq_key.pub"

    # Destroy signature and nonce
    _secure_delete "${bundle_dir}/master_signature"
    _secure_delete "${bundle_dir}/nonce"

    # Destroy any temporary sign data
    _secure_delete "${bundle_dir}/.sign_data"

    # Destroy export directory if it exists
    if [[ -d "${bundle_dir}/export" ]]; then
        for f in "${bundle_dir}/export"/*; do
            [[ -f "$f" ]] && _secure_delete "$f"
        done
        rmdir "${bundle_dir}/export" 2>/dev/null || true
    fi

    # Destroy session ID last (used for logging)
    _secure_delete "${bundle_dir}/session_id"

    # Remove the bundle directory
    rmdir "${bundle_dir}" 2>/dev/null || rm -rf "${bundle_dir}"

    log_debug "Session ${session_id:0:16}... destroyed"
    return 0
}

# ── Destruction Verification ─────────────────────────────────────────────────

# verify_destruction BUNDLE_DIR
# Confirm that no residual key material remains in the session bundle.
# Returns 0 if clean, 1 if material remains.
verify_destruction() {
    local bundle_dir="$1"

    if [[ ! -d "${bundle_dir}" ]]; then
        log_debug "Session bundle directory removed — destruction verified"
        return 0
    fi

    local remaining=0
    local sensitive_files=(
        "session_key"
        "session_pq_key"
        "session_key.pub"
        "session_pq_key.pub"
        "master_signature"
        "nonce"
        "session_id"
        ".sign_data"
    )

    for f in "${sensitive_files[@]}"; do
        if [[ -f "${bundle_dir}/${f}" ]]; then
            log_error "Residual key material found: ${bundle_dir}/${f}"
            (( remaining++ )) || true
        fi
    done

    if (( remaining > 0 )); then
        log_error "${remaining} file(s) remain after destruction — SECURITY CONCERN"
        return 1
    fi

    log_debug "Destruction verified: no residual key material"
    return 0
}

# ── Cleanup All Sessions ────────────────────────────────────────────────────

# cleanup_stale_sessions
# Destroy any leftover session bundles that were not properly cleaned up.
# This handles edge cases like interrupted connections or crashes.
cleanup_stale_sessions() {
    log_section "OTK-PQ Stale Session Cleanup"

    if [[ ! -d "${OTK_SESSION_DIR}" ]]; then
        log_info "No session directory — nothing to clean up"
        return 0
    fi

    local count=0 destroyed=0
    for bundle_dir in "${OTK_SESSION_DIR}"/*/; do
        [[ -d "${bundle_dir}" ]] || continue
        (( count++ )) || true

        local session_id="unknown"
        [[ -f "${bundle_dir}/session_id" ]] && session_id="$(cat "${bundle_dir}/session_id")"

        log_warn "Destroying stale session: ${session_id:0:16}..."
        destroy_session "${bundle_dir}"
        verify_destruction "${bundle_dir}" && (( destroyed++ )) || true
    done

    if (( count == 0 )); then
        log_success "No stale sessions found"
    else
        log_success "Cleaned up ${destroyed}/${count} stale session(s)"
    fi
}

# ── Session Lock ─────────────────────────────────────────────────────────────

# mark_session_used BUNDLE_DIR
# Mark a session bundle as used (prevents reuse on client side).
# The server-side revocation ledger provides the authoritative check,
# but this client-side flag provides defense-in-depth.
mark_session_used() {
    local bundle_dir="$1"

    if [[ ! -d "${bundle_dir}" ]]; then
        log_error "Cannot mark session as used: bundle not found"
        return 1
    fi

    touch "${bundle_dir}/.used"
    chmod "${OTK_PRIVATE_KEY_PERMS}" "${bundle_dir}/.used"
    log_debug "Session marked as used"
}

# is_session_used BUNDLE_DIR
# Check if a session has already been used.
is_session_used() {
    local bundle_dir="$1"

    if [[ -f "${bundle_dir}/.used" ]]; then
        return 0  # true — session was used
    fi
    return 1  # false — session not yet used
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"

    case "${command}" in
        destroy)
            local bundle_dir="${2:-}"
            if [[ -z "${bundle_dir}" ]]; then
                log_fatal "Usage: $(basename "$0") destroy <bundle_dir>"
            fi
            destroy_session "${bundle_dir}"
            verify_destruction "${bundle_dir}"
            log_success "Session destroyed and verified"
            ;;
        cleanup)
            cleanup_stale_sessions
            ;;
        verify)
            local bundle_dir="${2:-}"
            if [[ -z "${bundle_dir}" ]]; then
                log_fatal "Usage: $(basename "$0") verify <bundle_dir>"
            fi
            if verify_destruction "${bundle_dir}"; then
                log_success "Destruction verified: no residual material"
            else
                log_error "Destruction verification FAILED"
                exit 1
            fi
            ;;
        *)
            echo "OTK-PQ Layer 3 — One-Time Execution & Destruction"
            echo "──────────────────────────────────────────────────"
            echo
            echo "Usage: $(basename "$0") <command>"
            echo
            echo "Commands:"
            echo "  destroy <bundle_dir>  Securely destroy a session bundle"
            echo "  verify <bundle_dir>   Verify destruction is complete"
            echo "  cleanup               Destroy all stale session bundles"
            echo
            echo "Destruction is a feature — every key is temporary,"
            echo "every session is final."
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
