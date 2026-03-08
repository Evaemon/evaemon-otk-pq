#!/bin/bash
set -eo pipefail

# Performance benchmarking tool for post-quantum SSH algorithms.
#
# Measures (averaged over N iterations):
#   - Key generation time  (ssh-keygen wall-clock ms)
#   - Key sizes            (private + public key file bytes)
#   - SSH handshake time   (wall-clock ms to first authenticated remote echo)
#
# Results are printed as a formatted table and saved to a CSV file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/config.sh"
source "${SCRIPT_DIR}/../../shared/functions.sh"

PERF_LOG="${BUILD_DIR}/perf_$(date "+%Y%m%d_%H%M%S").csv"
TEMP_KEYDIR="$(mktemp -d)"

trap 'rm -rf "${TEMP_KEYDIR}"' EXIT

# ── Timing helper ────────────────────────────────────────────────────────────

# elapsed_ms COMMAND [ARGS...]
# Runs the command, prints elapsed wall-clock milliseconds to stdout.
elapsed_ms() {
    local start end
    start="$(date +%s%3N)"
    "$@" &>/dev/null
    end="$(date +%s%3N)"
    echo $(( end - start ))
}

# ── Per-algorithm benchmarks ─────────────────────────────────────────────────

bench_keygen() {
    local algo="$1"
    local keyfile="${TEMP_KEYDIR}/id_${algo}"
    rm -f "${keyfile}" "${keyfile}.pub"

    if [[ ! -x "${BIN_DIR}/ssh-keygen" ]]; then
        echo "N/A"; return
    fi

    elapsed_ms "${BIN_DIR}/ssh-keygen" -t "${algo}" -f "${keyfile}" -N ""
}

bench_key_sizes() {
    local algo="$1"
    local keyfile="${TEMP_KEYDIR}/id_${algo}"
    local priv_bytes pub_bytes
    priv_bytes="$(stat -c "%s" "${keyfile}"     2>/dev/null || echo 0)"
    pub_bytes="$( stat -c "%s" "${keyfile}.pub" 2>/dev/null || echo 0)"
    echo "${priv_bytes} ${pub_bytes}"
}

bench_handshake() {
    local host="$1" port="$2" user="$3" algo="$4"
    local keyfile="${SSH_DIR}/id_${algo}"

    if [[ ! -x "${BIN_DIR}/ssh" || ! -f "$keyfile" ]]; then
        echo "N/A"; return
    fi

    elapsed_ms "${BIN_DIR}/ssh" \
        -o "KexAlgorithms=${PQ_KEX_LIST}" \
        -o "HostKeyAlgorithms=${algo}" \
        -o "PubkeyAcceptedKeyTypes=${algo}" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -o "StrictHostKeyChecking=accept-new" \
        -i "${keyfile}" \
        -p "${port}" \
        "${user}@${host}" \
        "exit"
}

# ── Report formatting ────────────────────────────────────────────────────────

print_header() {
    printf "\n%-35s %10s %12s %11s %14s\n" \
        "Algorithm" "Keygen(ms)" "PrivKey(B)" "PubKey(B)" "Handshake(ms)"
    printf "%-35s %10s %12s %11s %14s\n" \
        "-----------------------------------" \
        "----------" "------------" "-----------" "--------------"
}

print_row() {
    printf "%-35s %10s %12s %11s %14s\n" "$1" "$2" "$3" "$4" "$5"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_section "Post-Quantum SSH Performance Benchmark"

    echo "Benchmark scope:"
    echo "1. All supported algorithms"
    echo "2. Select specific algorithms"
    read -rp "Choice (1-2): " bench_mode

    local test_algos=()
    if [[ "$bench_mode" == "2" ]]; then
        list_algorithms
        read -rp "Enter algorithm numbers (space-separated, e.g. 1 3 5): " -a choices
        for c in "${choices[@]}"; do
            validate_algorithm_choice "$c" "${#ALGORITHMS[@]}" || exit 1
            test_algos+=("${ALGORITHMS[$((c-1))]}")
        done
    else
        test_algos=("${ALGORITHMS[@]}")
    fi

    local do_handshake=false
    local server_host="" server_port="22" server_user=""
    read -rp "Include SSH handshake benchmark? (requires a running server) (y/N): " do_hs
    if [[ "$do_hs" == "y" || "$do_hs" == "Y" ]]; then
        do_handshake=true
        read -rp "Server host/IP: " server_host
        validate_ip "$server_host" || exit 1
        read -rp "Server username: " server_user
        validate_username "$server_user" || exit 1
        read -rp "SSH port [22]: " server_port
        server_port="${server_port:-22}"
        validate_port "$server_port" || exit 1
    fi

    local iterations=3
    read -rp "Iterations per algorithm for averaging [3]: " iters_input
    iters_input="${iters_input:-3}"
    if [[ "$iters_input" =~ ^[1-9][0-9]*$ ]]; then
        iterations="$iters_input"
    fi

    log_info "Running benchmark (${iterations} iteration(s) per algorithm, 1 warm-up)..."
    mkdir -p "$(dirname "$PERF_LOG")"
    touch "$PERF_LOG" && chmod 600 "$PERF_LOG"
    echo "algorithm,keygen_avg_ms,priv_key_bytes,pub_key_bytes,handshake_avg_ms" > "$PERF_LOG"

    print_header

    for algo in "${test_algos[@]}"; do
        # Key generation — discard one warm-up run before measured iterations
        local keygen_total=0 keygen_ms="N/A"
        if [[ -x "${BIN_DIR}/ssh-keygen" ]]; then
            log_debug "Warm-up keygen for ${algo}..."
            bench_keygen "$algo" >/dev/null
            for (( i=0; i<iterations; i++ )); do
                local t
                t="$(bench_keygen "$algo")"
                keygen_total=$(( keygen_total + t ))
            done
            keygen_ms=$(( keygen_total / iterations ))
        fi

        # Key sizes (from last keygen run in temp dir)
        local priv_b=0 pub_b=0
        read -r priv_b pub_b <<< "$(bench_key_sizes "$algo")"

        # Handshake timing — discard one warm-up connection before measured iterations
        local hs_ms="N/A"
        if [[ "$do_handshake" == true ]]; then
            log_debug "Warm-up handshake for ${algo}..."
            bench_handshake "$server_host" "$server_port" "$server_user" "$algo" >/dev/null
            local hs_total=0 hs_ok=true
            for (( i=0; i<iterations; i++ )); do
                local t
                t="$(bench_handshake "$server_host" "$server_port" "$server_user" "$algo")"
                if [[ "$t" == "N/A" ]]; then
                    hs_ok=false; break
                fi
                hs_total=$(( hs_total + t ))
            done
            [[ "$hs_ok" == true ]] && hs_ms=$(( hs_total / iterations ))
        fi

        print_row "$algo" "$keygen_ms" "$priv_b" "$pub_b" "$hs_ms"
        echo "${algo},${keygen_ms},${priv_b},${pub_b},${hs_ms}" >> "$PERF_LOG"
    done

    echo
    log_info "Results saved to: ${PERF_LOG}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
