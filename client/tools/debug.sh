#!/bin/bash
set -eo pipefail

# SSH debug and diagnostics tool for post-quantum connections.
#
# Provides:
#   - Local environment inspection (binary versions, key inventory, permissions)
#   - Algorithm negotiation probe (what the server advertises via ssh-keyscan)
#   - Verbose SSH connection attempt (-vvv) with output saved to a log file
#   - Remote environment inspection (authorized_keys, ~/.ssh permissions)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"

DEBUG_LOG="${BUILD_DIR}/debug_$(date "+%Y%m%d_%H%M%S").log"

# ── Sections ─────────────────────────────────────────────────────────────────

inspect_local_env() {
    log_section "Local Environment"

    log_info "OQS binary directory: ${BIN_DIR}"
    for bin in ssh ssh-keygen ssh-keyscan; do
        local full="${BIN_DIR}/${bin}"
        if [[ -x "$full" ]]; then
            local ver
            ver="$("$full" -V 2>&1 || true)"
            log_info "  ${bin}: ${ver}"
        else
            log_warn "  ${bin}: NOT FOUND at ${full}"
        fi
    done

    log_section "Key Inventory (${SSH_DIR})"
    local found=false
    while IFS= read -r -d '' pubkey; do
        found=true
        local privkey="${pubkey%.pub}"
        local priv_perms pub_perms
        priv_perms="$(stat -c "%a" "$privkey" 2>/dev/null || echo "missing")"
        pub_perms="$(stat -c "%a" "$pubkey"  2>/dev/null || echo "missing")"

        local fp
        fp="$("${BIN_DIR}/ssh-keygen" -lf "$pubkey" 2>/dev/null || echo "unreadable")"

        log_info "  Key pair: $(basename "$privkey")"
        log_info "    Private perms : ${priv_perms} $([ "$priv_perms" == "600" ] && echo "[OK]" || echo "[WARN: should be 600]")"
        log_info "    Public  perms : ${pub_perms}"
        log_info "    Fingerprint   : ${fp}"
    done < <(find "${SSH_DIR}" -maxdepth 1 -name "id_ssh-*.pub" -print0 2>/dev/null)

    if [[ "$found" == false ]]; then
        log_warn "No post-quantum keys found in ${SSH_DIR}."
    fi

    log_section "known_hosts"
    local kh="${SSH_DIR}/known_hosts"
    if [[ -f "$kh" ]]; then
        local count
        count="$(wc -l < "$kh")"
        log_info "  ${kh}: ${count} entry/entries"
    else
        log_warn "  known_hosts not found -- first connection to any server will prompt for trust."
    fi
}

probe_server_algorithms() {
    local host="$1" port="$2"
    log_section "Server Algorithm Probe (${host}:${port})"

    if [[ ! -x "${BIN_DIR}/ssh-keyscan" ]]; then
        log_warn "ssh-keyscan not available -- skipping algorithm probe."
        return
    fi

    log_info "Running ssh-keyscan (this may take a few seconds)..."
    local output
    output=$( "${BIN_DIR}/ssh-keyscan" -p "${port}" "${host}" 2>&1 || true )
    if [[ -z "$output" ]]; then
        log_warn "No response from ${host}:${port}. Is sshd running?"
        return
    fi

    log_info "Advertised host keys:"
    while IFS= read -r line; do
        log_info "  ${line}"
    done <<< "$output"
}

verbose_connect() {
    local host="$1" port="$2" user="$3" algo="$4"
    local key="${SSH_DIR}/id_${algo}"
    log_section "Verbose SSH Attempt (-vvv)"
    log_info "Output will be saved to: ${DEBUG_LOG}"

    if [[ ! -f "$key" ]]; then
        log_error "Key not found: ${key} -- skipping verbose connect."
        return
    fi

    mkdir -p "$(dirname "$DEBUG_LOG")"
    # Restrict permissions before writing: the -vvv log can contain key
    # fingerprints and negotiation details that should not be world-readable.
    touch "$DEBUG_LOG" && chmod 600 "$DEBUG_LOG"

    # Run with maximum verbosity; capture stderr (where -v output goes).
    # || true prevents pipefail from aborting on auth failure.
    "${BIN_DIR}/ssh" \
        -vvv \
        -o "KexAlgorithms=${PQ_KEX_LIST}" \
        -o "HostKeyAlgorithms=${algo}" \
        -o "PubkeyAcceptedKeyTypes=${algo}" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -o "StrictHostKeyChecking=accept-new" \
        -i "${key}" \
        -p "${port}" \
        "${user}@${host}" \
        "echo DEBUG_OK" \
        > "${DEBUG_LOG}" 2>&1 || true

    if grep -q "DEBUG_OK" "${DEBUG_LOG}" 2>/dev/null; then
        log_info "Connection succeeded."
    else
        log_warn "Connection did not complete successfully -- check ${DEBUG_LOG} for details."
    fi

    log_info "--- Last 30 lines of debug log ---"
    tail -n 30 "${DEBUG_LOG}" | while IFS= read -r line; do
        log_debug "  ${line}"
    done
    log_info "Full log: ${DEBUG_LOG}"
}

inspect_remote_env() {
    local host="$1" port="$2" user="$3" algo="$4"
    local key="${SSH_DIR}/id_${algo}"
    log_section "Remote Environment (${user}@${host})"

    if [[ ! -f "$key" ]]; then
        log_warn "Key not found -- skipping remote inspection."
        return
    fi

    local remote_info
    remote_info=$( "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${PQ_KEX_LIST}" \
        -o "HostKeyAlgorithms=${algo}" \
        -o "PubkeyAcceptedKeyTypes=${algo}" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -o "StrictHostKeyChecking=accept-new" \
        -i "${key}" -p "${port}" "${user}@${host}" \
        'echo "--- authorized_keys ---" && \
         cat ~/.ssh/authorized_keys 2>/dev/null || echo "(empty or missing)" && \
         echo "--- ~/.ssh permissions ---" && \
         ls -la ~/.ssh 2>/dev/null' \
        2>&1 || echo "REMOTE_INSPECT_FAILED" )

    if echo "$remote_info" | grep -q "REMOTE_INSPECT_FAILED"; then
        log_warn "Could not connect to retrieve remote info."
    else
        while IFS= read -r line; do
            log_info "  ${line}"
        done <<< "$remote_info"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_section "Post-Quantum SSH Debug Tool"

    inspect_local_env

    read -rp "Enter server host/IP (leave blank to skip remote checks): " server_host
    if [[ -z "$server_host" ]]; then
        log_info "Skipping remote checks."
        exit 0
    fi
    validate_ip "$server_host" || exit 1

    read -rp "Server username: " server_user
    validate_username "$server_user" || exit 1

    read -rp "SSH port [22]: " server_port
    server_port="${server_port:-22}"
    validate_port "$server_port" || exit 1

    echo
    list_algorithms
    read -rp "Algorithm number: " alg_choice
    validate_algorithm_choice "$alg_choice" "${#ALGORITHMS[@]}" || exit 1
    local algo="${ALGORITHMS[$((alg_choice-1))]}"

    probe_server_algorithms "$server_host" "$server_port"
    verbose_connect         "$server_host" "$server_port" "$server_user" "$algo"
    inspect_remote_env      "$server_host" "$server_port" "$server_user" "$algo"

    log_section "Debug Complete"
    log_info "Full verbose log: ${DEBUG_LOG}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
