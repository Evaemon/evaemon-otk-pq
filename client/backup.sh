#!/bin/bash
set -eo pipefail

# Backup and restore post-quantum SSH keys and configuration.
#
# backup  — archives ~/.ssh/id_ssh-* keys + known_hosts into an AES-256
#           encrypted tarball; the destination path is printed on success.
# restore — decrypts a previously created backup and extracts it back into
#           ~/.ssh, preserving original file permissions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

_require_openssl() {
    if ! command -v openssl &>/dev/null; then
        log_fatal "openssl is required for encrypted backups but was not found in PATH."
    fi
}

_default_backup_path() {
    local ts
    ts="$(date "+%Y%m%d_%H%M%S")"
    echo "${HOME}/evaemon_backup_${ts}.tar.gz.enc"
}

# ── Backup ───────────────────────────────────────────────────────────────────

do_backup() {
    _require_openssl

    local dest="${1:-$(_default_backup_path)}"

    # Gather files: all PQ key pairs + known_hosts
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "${SSH_DIR}" -maxdepth 1 \
        \( -name "id_ssh-*" -o -name "known_hosts" \) \
        -print0 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "No post-quantum keys found in ${SSH_DIR}. Nothing to back up."
        exit 0
    fi

    log_info "Found ${#files[@]} file(s) to back up:"
    for f in "${files[@]}"; do
        log_info "  $f"
    done

    # Prompt for passphrase (twice, to confirm)
    local pass pass2
    read -rsp "Enter backup passphrase: " pass; echo
    read -rsp "Confirm passphrase: "      pass2; echo
    if [[ "$pass" != "$pass2" ]]; then
        log_fatal "Passphrases do not match."
    fi
    if [[ -z "$pass" ]]; then
        log_fatal "Passphrase must not be empty."
    fi

    log_info "Creating encrypted backup -> ${dest} ..."

    # Write passphrase to a temp file so it is not exposed in the process list
    # via /proc/<pid>/cmdline (which -pass pass:... would be).
    local pass_file
    pass_file="$(mktemp)"
    chmod 600 "$pass_file"
    printf '%s' "$pass" > "$pass_file"
    unset pass pass2
    # Ensure temp file is removed on exit/error
    trap 'rm -f "${pass_file}"' RETURN

    # tar the files (relative to SSH_DIR) then pipe through openssl enc
    local rel_files=()
    for f in "${files[@]}"; do
        rel_files+=("${f#${SSH_DIR}/}")
    done
    tar -czf - -C "${SSH_DIR}" -- "${rel_files[@]}" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass "file:${pass_file}" \
            -out "${dest}"

    rm -f "$pass_file"
    chmod 600 "${dest}"
    log_info "Backup complete: ${dest}"
    log_warn "Store this file and its passphrase securely -- treat it like a private key."
}

# ── Restore ──────────────────────────────────────────────────────────────────

do_restore() {
    _require_openssl

    local src="$1"
    if [[ -z "$src" ]]; then
        read -rp "Enter path to backup file: " src
    fi
    validate_file_exists "$src" || exit 1

    read -rsp "Enter backup passphrase: " pass; echo
    if [[ -z "$pass" ]]; then
        log_fatal "Passphrase must not be empty."
    fi

    log_info "Restoring backup from ${src} -> ${SSH_DIR} ..."

    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"

    # Write passphrase to a temp file to avoid exposure in the process list.
    local pass_file
    pass_file="$(mktemp)"
    chmod 600 "$pass_file"
    printf '%s' "$pass" > "$pass_file"
    unset pass
    trap 'rm -f "${pass_file}"' RETURN

    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
            -pass "file:${pass_file}" \
            -in "${src}" \
            | tar -xzf - -C "${SSH_DIR}" 2>/dev/null; then
        rm -f "$pass_file"
        log_fatal "Restore failed — wrong passphrase or corrupted backup file."
    fi
    rm -f "$pass_file"

    # Re-apply strict permissions on any restored private keys
    while IFS= read -r -d '' keyfile; do
        chmod 600 "$keyfile"
        log_debug "Set 600 on ${keyfile}"
    done < <(find "${SSH_DIR}" -maxdepth 1 -name "id_ssh-*" ! -name "*.pub" -print0 2>/dev/null)

    log_info "Restore complete. Keys are in ${SSH_DIR}."
}

# ── Main ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 {backup [DEST_FILE] | restore [SRC_FILE]}"
    echo
    echo "  backup  [DEST]  Encrypt and archive PQ keys to DEST (default: ~/evaemon_backup_<timestamp>.tar.gz.enc)"
    echo "  restore [SRC]   Decrypt and restore keys from SRC"
}

main() {
    local action="${1:-}"

    if [[ -z "$action" ]]; then
        echo "Post-Quantum SSH Key Backup Tool"
        echo "1. Backup keys"
        echo "2. Restore keys"
        read -rp "Select option (1-2): " action_choice
        case "$action_choice" in
            1) action="backup" ;;
            2) action="restore" ;;
            *) log_fatal "Invalid choice." ;;
        esac
    fi

    case "$action" in
        backup)  do_backup  "${2:-}" ;;
        restore) do_restore "${2:-}" ;;
        *)       usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
