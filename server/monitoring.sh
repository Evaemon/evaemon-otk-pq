#!/bin/bash
set -eo pipefail

# Post-quantum sshd monitoring tool.
#
# Displays:
#   1. Service status (systemctl / process check fallback)
#   2. Quantum readiness report (algorithm analysis + readiness score)
#   3. Active SSH connections on the configured port
#   4. Recent authentication events from the system journal / auth log
#   5. PQ algorithm negotiation events
#   6. Optional continuous watch mode (polls every N seconds)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/config.sh"
source "${SCRIPT_DIR}/../shared/functions.sh"

# ── Monitoring sections ───────────────────────────────────────────────────────

show_service_status() {
    log_section "Service Status"

    if command -v systemctl &>/dev/null; then
        local status
        status="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown")"
        log_info "  systemctl status: ${status}"

        if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            log_info "  Service is RUNNING"
            systemctl status "${SERVICE_NAME}.service" --no-pager -l 2>/dev/null | \
                while IFS= read -r line; do log_info "    ${line}"; done
        else
            log_warn "  Service is NOT running (${status})"
            log_warn "  Start with: systemctl start ${SERVICE_NAME}.service"
        fi
    else
        # No systemd — check via process
        local pid
        pid="$(_sshd_pid)"
        if [[ -n "$pid" ]]; then
            log_info "  sshd is running (PID ${pid})"
            ps -p "$pid" -o pid,user,%cpu,%mem,etime,args --no-headers 2>/dev/null | \
                while IFS= read -r line; do log_info "    ${line}"; done
        else
            log_warn "  sshd is NOT running"
        fi
    fi
}

show_active_connections() {
    log_section "Active SSH Connections"

    local port
    port="$(_configured_port)"

    if command -v ss &>/dev/null; then
        local conns
        conns="$(ss -tnp "sport = :${port}" 2>/dev/null | tail -n +2 || true)"
        if [[ -z "$conns" ]]; then
            log_info "  No active connections on port ${port}."
        else
            log_info "  Connections on port ${port}:"
            while IFS= read -r line; do
                log_info "    ${line}"
            done <<< "$conns"
        fi
    elif command -v netstat &>/dev/null; then
        local conns
        conns="$(netstat -tnp 2>/dev/null | grep ":${port} " || true)"
        if [[ -z "$conns" ]]; then
            log_info "  No active connections on port ${port}."
        else
            while IFS= read -r line; do log_info "    ${line}"; done <<< "$conns"
        fi
    else
        log_warn "  Neither ss nor netstat found -- cannot list connections."
    fi
}

show_auth_events() {
    local n="${1:-20}"
    log_section "Recent Authentication Events (last ${n} entries)"

    if command -v journalctl &>/dev/null; then
        journalctl -u "${SERVICE_NAME}.service" -n "${n}" --no-pager 2>/dev/null | \
            while IFS= read -r line; do log_info "  ${line}"; done || \
            log_warn "  No journal entries found for ${SERVICE_NAME}."
    elif [[ -f /var/log/auth.log ]]; then
        grep -i "sshd" /var/log/auth.log | tail -n "${n}" | \
            while IFS= read -r line; do log_info "  ${line}"; done
    elif [[ -f /var/log/secure ]]; then
        grep -i "sshd" /var/log/secure | tail -n "${n}" | \
            while IFS= read -r line; do log_info "  ${line}"; done
    else
        log_warn "  No accessible auth log found."
    fi
}

show_pq_algorithm_events() {
    local n="${1:-30}"
    log_section "Post-Quantum Algorithm Negotiation Events (last ${n} log lines searched)"

    local algo_pattern
    algo_pattern="$(IFS='|'; echo "${ALGORITHMS[*]}")"
    if [[ -z "$algo_pattern" ]]; then
        log_warn "  No algorithms configured -- skipping PQ event search."
        return
    fi

    local matches=""
    if command -v journalctl &>/dev/null; then
        matches="$(journalctl -u "${SERVICE_NAME}.service" -n "${n}" --no-pager 2>/dev/null \
                   | grep -E "${algo_pattern}" || true)"
    elif [[ -f /var/log/auth.log ]]; then
        matches="$(grep -E "${algo_pattern}" /var/log/auth.log 2>/dev/null | tail -n "${n}" || true)"
    elif [[ -f /var/log/secure ]]; then
        matches="$(grep -E "${algo_pattern}" /var/log/secure 2>/dev/null | tail -n "${n}" || true)"
    fi

    if [[ -z "$matches" ]]; then
        log_info "  No PQ algorithm negotiation events found in recent logs."
    else
        while IFS= read -r line; do log_info "  ${line}"; done <<< "$matches"
    fi
}

# ── Quantum Readiness Report ─────────────────────────────────────────────────

show_security_report() {
    log_section "Quantum Readiness Report"

    local config="${CONFIG_FILE}"
    if [[ ! -f "$config" ]]; then
        log_warn "  sshd_config not found at ${config} — cannot assess readiness."
        return
    fi

    # ── Negotiated host key algorithms ──
    local host_algos=""
    host_algos="$(grep -i "^HostKeyAlgorithms " "$config" 2>/dev/null | head -1 | awk '{print $2}')"
    if [[ -n "$host_algos" ]]; then
        log_info "  Host key algorithms: ${host_algos}"
    else
        log_warn "  HostKeyAlgorithms directive not found."
    fi

    # ── Negotiated KEX ──
    local kex_algos=""
    kex_algos="$(grep -i "^KexAlgorithms " "$config" 2>/dev/null | head -1 | awk '{print $2}')"
    if [[ -n "$kex_algos" ]]; then
        log_info "  KEX algorithms:      ${kex_algos}"
    else
        log_warn "  KexAlgorithms directive not found."
    fi

    # ── Score calculation ──
    # Points (max 100):
    #   +30  PQ host key algorithm present
    #   +10  multi-family: at least 2 different PQ families in HostKeyAlgorithms
    #   +10  ML-DSA (NIST FIPS 204 primary) in host keys
    #   +10  hash-based (SPHINCS+/SLH-DSA) in host keys
    #   +20  PQ KEX (mlkem) present
    #   +10  pure PQ KEX option (mlkem without nistp/x25519) present
    #   +10  password auth disabled
    local score=0 notes=()

    # PQ host key?
    local has_pq_host=false
    for algo in "${ALGORITHMS[@]}"; do
        if [[ ",$host_algos," == *",$algo,"* || "$host_algos" == "$algo" ]]; then
            has_pq_host=true
            break
        fi
    done
    if $has_pq_host; then
        (( score += 30 ))
    else
        notes+=("No PQ host key algorithm configured (-30)")
    fi

    # Multi-family?
    local has_lattice=false has_hash=false has_mayo=false families=0
    if [[ "$host_algos" == *"falcon"* || "$host_algos" == *"mldsa"* ]]; then
        has_lattice=true; (( families++ ))
    fi
    if [[ "$host_algos" == *"sphincs"* || "$host_algos" == *"slhdsa"* ]]; then
        has_hash=true; (( families++ ))
    fi
    if [[ "$host_algos" == *"mayo"* ]]; then
        has_mayo=true; (( families++ ))
    fi
    if (( families >= 2 )); then
        (( score += 10 ))
    else
        notes+=("Only ${families} PQ algorithm family — deploy multi-family for resilience (-10)")
    fi

    # ML-DSA (FIPS 204)?
    if [[ "$host_algos" == *"mldsa"* ]]; then
        (( score += 10 ))
    else
        notes+=("ML-DSA (NIST FIPS 204 primary) not in host keys (-10)")
    fi

    # Hash-based (SPHINCS+/SLH-DSA)?
    if [[ "$host_algos" == *"sphincs"* || "$host_algos" == *"slhdsa"* ]]; then
        (( score += 10 ))
    else
        notes+=("No hash-based algorithm (SPHINCS+/SLH-DSA) — no lattice-independent fallback (-10)")
    fi

    # PQ KEX?
    if [[ "$kex_algos" == *"mlkem"* ]]; then
        (( score += 20 ))
    else
        notes+=("No ML-KEM key exchange — session encryption is not quantum-safe (-20)")
    fi

    # Pure PQ KEX? (mlkem without classical hybrid component)
    if [[ "$kex_algos" == *"mlkem1024-sha384"* || "$kex_algos" == *"mlkem768-sha256"* ]]; then
        (( score += 10 ))
    else
        notes+=("No pure PQ KEX option — only hybrid KEX available (-10)")
    fi

    # Password auth disabled?
    local pw_auth
    pw_auth="$(grep -i "^PasswordAuthentication " "$config" 2>/dev/null | awk '{print tolower($2)}' | head -1)"
    if [[ "$pw_auth" == "no" ]]; then
        (( score += 10 ))
    else
        notes+=("PasswordAuthentication is not disabled (-10)")
    fi

    # ── Print results ──
    echo
    local readiness_label
    if (( score >= 90 )); then
        readiness_label="EXCELLENT"
    elif (( score >= 70 )); then
        readiness_label="GOOD"
    elif (( score >= 50 )); then
        readiness_label="MODERATE"
    else
        readiness_label="NEEDS IMPROVEMENT"
    fi

    log_info "  Quantum readiness: ${score}% — ${readiness_label}"

    if $has_pq_host && [[ -n "$kex_algos" && "$kex_algos" == *"mlkem"* ]]; then
        local primary_host_algo="${host_algos%%,*}"
        local primary_kex="${kex_algos%%,*}"
        log_info "  Current negotiated:  ${primary_host_algo} + ${primary_kex}"
    fi

    if $has_lattice; then log_info "  [x] Lattice-based host key"; else log_warn "  [ ] Lattice-based host key"; fi
    if $has_hash;    then log_info "  [x] Hash-based host key (SPHINCS+/SLH-DSA)"; else log_warn "  [ ] Hash-based host key (SPHINCS+/SLH-DSA)"; fi
    if $has_mayo;    then log_info "  [x] Multivariate host key (MAYO)"; else log_info "  [ ] Multivariate host key (MAYO) — optional"; fi

    if [[ ${#notes[@]} -gt 0 ]]; then
        echo
        log_warn "  Recommendations:"
        for note in "${notes[@]}"; do
            log_warn "    - ${note}"
        done
    fi
}

show_uptime_and_load() {
    log_section "System Load"
    local pid
    pid="$(_sshd_pid)"
    if [[ -n "$pid" ]]; then
        local elapsed
        elapsed="$(ps -p "$pid" -o etime --no-headers 2>/dev/null | tr -d ' ' || echo "unknown")"
        log_info "  sshd PID ${pid} uptime: ${elapsed}"
    fi

    if [[ -f /proc/loadavg ]]; then
        local load
        load="$(cat /proc/loadavg 2>/dev/null)"
        log_info "  System load averages: ${load}"
    elif command -v uptime &>/dev/null; then
        local load
        load="$(uptime 2>/dev/null)"
        log_info "  ${load}"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

print_snapshot() {
    show_service_status
    show_security_report
    show_active_connections
    show_auth_events        20
    show_pq_algorithm_events 30
    show_uptime_and_load
}

main() {
    log_section "Post-Quantum sshd Monitor"

    echo "Options:"
    echo "1. One-shot status snapshot"
    echo "2. Continuous watch (refresh every N seconds)"
    read -rp "Choice (1-2) [1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
        1)
            print_snapshot
            ;;
        2)
            read -rp "Refresh interval in seconds [10]: " interval
            interval="${interval:-10}"
            if [[ ! "$interval" =~ ^[1-9][0-9]*$ ]]; then
                log_fatal "Interval must be a positive integer."
            fi
            log_info "Watching (Ctrl-C to stop, refresh every ${interval}s) ..."
            while true; do
                clear
                print_snapshot
                log_info "Next refresh in ${interval}s — Ctrl-C to quit."
                sleep "${interval}"
            done
            ;;
        *)
            log_fatal "Invalid choice."
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
