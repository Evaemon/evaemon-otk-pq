#!/bin/bash
set -eo pipefail

# Server-side diagnostics tool for post-quantum sshd.
#
# Reports:
#   1. sshd binary version and path
#   2. Active sshd_config with annotation of PQ-relevant directives
#   3. Configuration syntax check (sshd -t)
#   4. Host key inventory with fingerprints and permissions
#   5. Systemd service definition (if present)
#   6. Port conflict check
#   7. Recent sshd log tail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"

# ── Sections ──────────────────────────────────────────────────────────────────

diag_binary() {
    log_section "sshd Binary"

    for bin in sshd ssh-keygen ssh-keyscan; do
        local full="${SBIN_DIR}/${bin}"
        # ssh-keygen / ssh-keyscan live in BIN_DIR
        [[ "$bin" == "sshd" ]] || full="${BIN_DIR}/${bin}"

        if [[ -x "$full" ]]; then
            local ver
            ver="$("$full" -V 2>&1 || true)"
            log_info "  ${bin}: ${ver}"
            log_info "    Path: ${full}"
            log_info "    Size: $(stat -c "%s" "$full" 2>/dev/null || echo "unknown") bytes"
        else
            log_warn "  ${bin}: NOT FOUND at ${full}"
        fi
    done
}

diag_config() {
    log_section "sshd Configuration (${CONFIG_FILE})"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "  Config file not found: ${CONFIG_FILE}"
        log_warn "  Run server/server.sh to generate it."
        return
    fi

    log_info "  Contents:"
    while IFS= read -r line; do
        # Highlight PQ-relevant directives
        if echo "$line" | grep -qiE "^(HostKeyAlgorithms|PubkeyAcceptedKeyTypes|HostKey|Port)"; then
            log_info "  >> ${line}   [PQ-relevant]"
        else
            log_info "     ${line}"
        fi
    done < "$CONFIG_FILE"
}

diag_config_test() {
    log_section "Configuration Syntax Check"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "  Config not found -- skipping test."
        return
    fi
    if [[ ! -x "${SBIN_DIR}/sshd" ]]; then
        log_warn "  sshd binary not found -- skipping test."
        return
    fi

    local output rc=0
    output=$("${SBIN_DIR}/sshd" -t -f "${CONFIG_FILE}" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        log_info "  Configuration is VALID."
    else
        log_error "  Configuration has ERRORS:"
        while IFS= read -r line; do log_error "    ${line}"; done <<< "$output"
    fi
}

diag_host_keys() {
    log_section "Host Key Inventory (${KEY_DIR})"

    if [[ ! -d "$KEY_DIR" ]]; then
        log_warn "  Key directory not found: ${KEY_DIR}"
        return
    fi

    local found=false
    while IFS= read -r -d '' pubkey; do
        found=true
        local privkey="${pubkey%.pub}"
        local priv_perms pub_perms
        priv_perms="$(stat -c "%a" "$privkey" 2>/dev/null || echo "missing")"
        pub_perms="$(stat -c "%a" "$pubkey"   2>/dev/null || echo "missing")"

        local fp="unreadable"
        if [[ -x "${BIN_DIR}/ssh-keygen" ]]; then
            fp="$("${BIN_DIR}/ssh-keygen" -lf "$pubkey" 2>/dev/null || echo "unreadable")"
        fi

        log_info "  Host key: $(basename "$privkey")"
        log_info "    Private perms : ${priv_perms} $([ "$priv_perms" == "600" ] && echo "[OK]" || echo "[WARN: should be 600]")"
        log_info "    Public  perms : ${pub_perms}"
        log_info "    Fingerprint   : ${fp}"
    done < <(find "${KEY_DIR}" -maxdepth 1 -name "ssh_host_*.pub" -print0 2>/dev/null)

    if [[ "$found" == false ]]; then
        log_warn "  No host keys found in ${KEY_DIR}."
        log_warn "  Run server/server.sh to generate them."
    fi
}

diag_service_file() {
    log_section "Systemd Service Definition"

    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_warn "  Service file not found: ${SERVICE_FILE}"
        return
    fi

    log_info "  ${SERVICE_FILE}:"
    while IFS= read -r line; do
        log_info "    ${line}"
    done < "$SERVICE_FILE"

    if command -v systemctl &>/dev/null; then
        local enabled
        enabled="$(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown")"
        local active
        active="$(systemctl is-active  "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown")"
        log_info "  Enabled: ${enabled}  |  Active: ${active}"
    fi
}

diag_port_conflicts() {
    log_section "Port Conflict Check"

    local port
    port="$(_configured_port)"
    log_info "  Checking port ${port}..."

    local listeners=""
    if command -v ss &>/dev/null; then
        listeners="$(ss -tlnp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
    elif command -v netstat &>/dev/null; then
        listeners="$(netstat -tlnp 2>/dev/null | grep ":${port} " || true)"
    fi

    if [[ -z "$listeners" ]]; then
        log_info "  Nothing is listening on port ${port}."
    else
        log_info "  Listeners on port ${port}:"
        while IFS= read -r line; do log_info "    ${line}"; done <<< "$listeners"

        # Check if it's our sshd
        if echo "$listeners" | grep -q "${SBIN_DIR}/sshd\|sshd"; then
            log_info "  sshd is bound to this port."
        else
            log_warn "  Another process is already using port ${port} -- conflict possible."
        fi
    fi
}

diag_recent_logs() {
    local n="${1:-30}"
    log_section "Recent sshd Log Entries (last ${n})"

    if command -v journalctl &>/dev/null; then
        journalctl -u "${SERVICE_NAME}.service" -n "${n}" --no-pager 2>/dev/null | \
            while IFS= read -r line; do log_info "  ${line}"; done || \
            log_warn "  No journal entries for ${SERVICE_NAME}."
    elif [[ -f /var/log/auth.log ]]; then
        grep -i "sshd" /var/log/auth.log 2>/dev/null | tail -n "${n}" | \
            while IFS= read -r line; do log_info "  ${line}"; done
    elif [[ -f /var/log/secure ]]; then
        grep -i "sshd" /var/log/secure 2>/dev/null | tail -n "${n}" | \
            while IFS= read -r line; do log_info "  ${line}"; done
    else
        log_warn "  No accessible log source found."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_section "Post-Quantum sshd Diagnostics"

    diag_binary
    diag_config
    diag_config_test
    diag_host_keys
    diag_service_file
    diag_port_conflicts
    diag_recent_logs 30

    log_section "Diagnostics Complete"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
