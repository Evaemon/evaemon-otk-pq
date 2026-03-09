#!/bin/bash
set -eo pipefail

# OTK-PQ Revocation Ledger
#
# Server-side record of used session keys.  Once a session key hash is
# recorded here, any attempt to reuse that key is rejected immediately.
#
# Format: Each line is "TIMESTAMP SESSION_ID_HASH"
# The timestamp enables time-based pruning — entries older than
# OTK_LEDGER_PRUNE_DAYS are removed since those session keys would be
# rejected by nonce validation anyway.
#
# Concurrency: File-level locking via flock prevents corruption when
# multiple SSH sessions write to the ledger simultaneously.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/otk_config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"

# ── Initialization ───────────────────────────────────────────────────────────

# init_ledger
# Create the ledger file and directory with correct permissions if they do not exist.
# Returns 0 always (idempotent).
init_ledger() {
    if [[ ! -d "${OTK_LEDGER_DIR}" ]]; then
        mkdir -p "${OTK_LEDGER_DIR}"
        chmod "${OTK_DIR_PERMS}" "${OTK_LEDGER_DIR}"
        log_debug "Created ledger directory: ${OTK_LEDGER_DIR}"
    fi

    if [[ ! -f "${OTK_LEDGER_FILE}" ]]; then
        touch "${OTK_LEDGER_FILE}"
        chmod "${OTK_LEDGER_PERMS}" "${OTK_LEDGER_FILE}"
        log_debug "Initialized revocation ledger: ${OTK_LEDGER_FILE}"
    fi
}

# ── Locking ──────────────────────────────────────────────────────────────────

# _with_ledger_lock COMMAND [ARGS...]
# Execute a command while holding an exclusive lock on the ledger.
# Prevents concurrent writes from corrupting the file.
# Returns the exit code of COMMAND, or 1 if the lock cannot be acquired within 10s.
_with_ledger_lock() {
    init_ledger

    (
        flock -x -w 10 200 || {
            log_error "Could not acquire ledger lock within 10 seconds"
            return 1
        }
        "$@"
    ) 200>"${OTK_LEDGER_LOCK}"
}

# ── Core Operations ─────────────────────────────────────────────────────────

# _add_entry SESSION_ID
# Add a session ID hash to the revocation ledger (called under lock).
_add_entry() {
    local session_id="$1"
    local timestamp
    timestamp="$(date +%s)"

    echo "${timestamp} ${session_id}" >> "${OTK_LEDGER_FILE}"
    log_debug "Added to revocation ledger: ${session_id:0:16}..."
}

# _check_entry SESSION_ID
# Check if a session ID is already in the ledger (called under lock).
# Returns 0 if found (revoked), 1 if not found (new).
_check_entry() {
    local session_id="$1"

    if grep -q " ${session_id}$" "${OTK_LEDGER_FILE}" 2>/dev/null; then
        return 0  # Found — key is revoked
    fi
    return 1  # Not found — key is new
}

# ── Public API ───────────────────────────────────────────────────────────────

# ledger_add SESSION_ID
# Record a session key hash in the revocation ledger.
# Should be called after a session completes (or during, for extra safety).
# Returns 0 on success, 1 if SESSION_ID is empty.
ledger_add() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "Session ID must not be empty"
        return 1
    fi

    _with_ledger_lock _add_entry "${session_id}"
}

# ledger_check SESSION_ID
# Check if a session key has been revoked.
# Returns 0 if revoked (REJECT the session), 1 if new (allow).
ledger_check() {
    local session_id="$1"

    if [[ -z "${session_id}" ]]; then
        log_error "Session ID must not be empty"
        return 1
    fi

    init_ledger

    if _check_entry "${session_id}"; then
        log_warn "REVOKED: Session ${session_id:0:16}... found in revocation ledger"
        return 0  # Revoked — reject
    fi

    log_debug "Session ${session_id:0:16}... not in revocation ledger — OK"
    return 1  # Not revoked — allow
}

# ledger_prune
# Remove entries older than OTK_LEDGER_PRUNE_DAYS from the ledger.
# Called periodically or when the ledger exceeds OTK_LEDGER_MAX_ENTRIES.
# Returns 0 always.
ledger_prune() {
    init_ledger

    local cutoff_ts entry_count
    cutoff_ts="$(( $(date +%s) - (OTK_LEDGER_PRUNE_DAYS * 86400) ))"

    _with_ledger_lock _prune_entries "${cutoff_ts}"
}

# _prune_entries CUTOFF_TIMESTAMP
# Remove entries older than the cutoff (called under lock).
_prune_entries() {
    local cutoff_ts="$1"
    local original_count pruned_count

    original_count="$(wc -l < "${OTK_LEDGER_FILE}")"

    # Keep only entries with timestamp >= cutoff
    local tmp_file
    tmp_file="$(mktemp "${OTK_LEDGER_FILE}.tmp.XXXXXX")"
    trap 'rm -f "${tmp_file}"' RETURN

    while IFS= read -r line; do
        local entry_ts="${line%% *}"
        if [[ "${entry_ts}" =~ ^[0-9]+$ ]] && (( entry_ts >= cutoff_ts )); then
            echo "${line}"
        fi
    done < "${OTK_LEDGER_FILE}" > "${tmp_file}"

    mv "${tmp_file}" "${OTK_LEDGER_FILE}"
    chmod "${OTK_LEDGER_PERMS}" "${OTK_LEDGER_FILE}"

    pruned_count="$(wc -l < "${OTK_LEDGER_FILE}")"
    local removed=$(( original_count - pruned_count ))

    log_info "Ledger pruned: ${removed} entries removed, ${pruned_count} remaining"
}

# ledger_stats
# Display revocation ledger statistics.
# Returns 0 always.
ledger_stats() {
    init_ledger

    log_section "OTK-PQ Revocation Ledger Statistics"

    local entry_count
    entry_count="$(wc -l < "${OTK_LEDGER_FILE}")"
    log_info "Total entries:     ${entry_count}"
    log_info "Max entries:       ${OTK_LEDGER_MAX_ENTRIES}"
    log_info "Prune after:       ${OTK_LEDGER_PRUNE_DAYS} days"
    log_info "Ledger file:       ${OTK_LEDGER_FILE}"

    local file_size
    file_size="$(wc -c < "${OTK_LEDGER_FILE}" 2>/dev/null || echo 0)"
    log_info "Ledger size:       ${file_size} bytes"

    if (( entry_count > 0 )); then
        local oldest_ts newest_ts
        oldest_ts="$(head -1 "${OTK_LEDGER_FILE}" | awk '{print $1}')"
        newest_ts="$(tail -1 "${OTK_LEDGER_FILE}" | awk '{print $1}')"

        if [[ "${oldest_ts}" =~ ^[0-9]+$ ]]; then
            local oldest_date
            oldest_date="$(date -d "@${oldest_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${oldest_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")"
            log_info "Oldest entry:      ${oldest_date}"
        fi
        if [[ "${newest_ts}" =~ ^[0-9]+$ ]]; then
            local newest_date
            newest_date="$(date -d "@${newest_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "${newest_ts}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")"
            log_info "Newest entry:      ${newest_date}"
        fi
    fi

    if (( entry_count >= OTK_LEDGER_MAX_ENTRIES )); then
        log_warn "Ledger at capacity — pruning recommended"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"

    case "${command}" in
        add)
            ledger_add "${2:-}"
            log_success "Session added to revocation ledger"
            ;;
        check)
            if ledger_check "${2:-}"; then
                echo "REVOKED"
                exit 0
            else
                echo "OK"
                exit 0
            fi
            ;;
        prune)
            ledger_prune
            ;;
        stats)
            ledger_stats
            ;;
        init)
            init_ledger
            log_success "Revocation ledger initialized: ${OTK_LEDGER_FILE}"
            ;;
        *)
            echo "OTK-PQ Revocation Ledger"
            echo "──────────────────────────"
            echo
            echo "Usage: $(basename "$0") <command>"
            echo
            echo "Commands:"
            echo "  add <session_id>    Record a used session key hash"
            echo "  check <session_id>  Check if a session key is revoked"
            echo "  prune               Remove expired entries"
            echo "  stats               Display ledger statistics"
            echo "  init                Initialize the ledger file"
            echo
            echo "The revocation ledger prevents replay attacks by recording"
            echo "every used session key hash. Used keys can never be replayed."
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
