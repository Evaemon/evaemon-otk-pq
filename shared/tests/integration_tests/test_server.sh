#!/bin/bash
# Integration tests for server setup (server/server.sh helpers).
#
# Tests the host-key generation, sshd_config generation, and systemd service
# file creation logic in isolation — without actually starting sshd or
# touching /etc/systemd.  Each test writes into a temporary directory.
#
# If the OQS sshd / ssh-keygen binary is not present, tests that require it
# are skipped so the suite still passes in a build-only environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${PROJECT_ROOT}/shared/config.sh"
source "${PROJECT_ROOT}/shared/logging.sh"
source "${PROJECT_ROOT}/shared/validation.sh"

# ── Isolated scratch area ─────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
TEST_KEY_DIR="${WORK_DIR}/keys"
TEST_CONFIG_DIR="${WORK_DIR}/etc"
TEST_CONFIG_FILE="${TEST_CONFIG_DIR}/sshd_config"
TEST_PID_DIR="${WORK_DIR}/var/run"
TEST_SERVICE_FILE="${WORK_DIR}/evaemon-sshd.service"
TEST_INSTALL_DIR="${WORK_DIR}/install"
mkdir -p "${TEST_KEY_DIR}" "${TEST_CONFIG_DIR}" "${TEST_PID_DIR}" "${TEST_INSTALL_DIR}/libexec"

trap 'rm -rf "${WORK_DIR}"' EXIT

_have_sshd() {    [[ -x "${SBIN_DIR}/sshd" ]]; }
_have_keygen() {  [[ -x "${BIN_DIR}/ssh-keygen" ]]; }

# ── Inline versions of server.sh functions (isolated) ────────────────────────
# We re-implement them here pointing at WORK_DIR so we test the logic without
# side-effects on the real system.

_generate_host_key() {
    local key_type="$1"
    local host_key="${TEST_KEY_DIR}/ssh_host_${key_type}_key"
    if [[ ! -f "$host_key" ]]; then
        "${BIN_DIR}/ssh-keygen" -t "$key_type" -f "$host_key" -N "" &>/dev/null
    fi
}

# Mirror of server.sh _keytype_to_ssh_algo — maps key type names to SSH
# algorithm names used in sshd_config directives.
_keytype_to_ssh_algo() {
    case "$1" in
        ed25519) echo "ssh-ed25519" ;;
        rsa)     echo "rsa-sha2-512,rsa-sha2-256" ;;
        ecdsa)   echo "ecdsa-sha2-nistp256" ;;
        *)       echo "$1" ;;   # PQ algorithm names pass through unchanged
    esac
}

_create_sshd_config() {
    local keytypes=("$@")
    local algo_parts=()
    for kt in "${keytypes[@]}"; do
        algo_parts+=("$(_keytype_to_ssh_algo "$kt")")
    done
    local algo_list
    algo_list="$(IFS=','; echo "${algo_parts[*]}")"

    local has_classical=false
    for kt in "${keytypes[@]}"; do
        for ck in "${CLASSICAL_KEYTYPES[@]}"; do
            [[ "$kt" == "$ck" ]] && has_classical=true && break 2
        done
    done
    local pq_kex_list kex_list
    pq_kex_list="$(IFS=','; echo "${KEX_ALGORITHMS[*]}")"
    if [[ "$has_classical" == true ]]; then
        kex_list="${pq_kex_list},${CLASSICAL_KEX_ALGORITHMS}"
    else
        kex_list="${pq_kex_list}"
    fi

    {
        echo "Port 2222"
        for kt in "${keytypes[@]}"; do
            echo "HostKey ${TEST_KEY_DIR}/ssh_host_${kt}_key"
        done
        echo "HostKeyAlgorithms ${algo_list}"
        echo "PubkeyAcceptedKeyTypes ${algo_list}"
        echo "KexAlgorithms ${kex_list}"
        echo "AuthorizedKeysFile .ssh/authorized_keys"
        echo "PermitRootLogin no"
        echo "StrictModes yes"
        echo "PidFile ${TEST_PID_DIR}/sshd.pid"
        echo "Subsystem sftp ${TEST_INSTALL_DIR}/libexec/sftp-server"
    } > "${TEST_CONFIG_FILE}"
}

_create_service_file() {
    cat > "${TEST_SERVICE_FILE}" <<EOF
[Unit]
Description=Post-Quantum SSH Server
After=network.target

[Service]
Type=simple
ExecStart=${SBIN_DIR}/sshd -f ${TEST_CONFIG_FILE} -D
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

# ── Host key generation ───────────────────────────────────────────────────────

describe "host key generation"

it "ssh-keygen binary is available (or will be skipped)"
if _have_keygen; then pass; else skip "OQS ssh-keygen not built yet"; fi

it "generates a host private key for ssh-falcon1024"
if ! _have_keygen; then skip "OQS ssh-keygen not present"
else
    _generate_host_key "ssh-falcon1024"
    assert_file_exists "${TEST_KEY_DIR}/ssh_host_ssh-falcon1024_key"
fi

it "generates a host public key for ssh-falcon1024"
if ! _have_keygen; then skip "OQS ssh-keygen not present"
else
    assert_file_exists "${TEST_KEY_DIR}/ssh_host_ssh-falcon1024_key.pub"
fi

it "host private key is non-empty"
if ! _have_keygen; then skip "OQS ssh-keygen not present"
else
    size="$(stat -c "%s" "${TEST_KEY_DIR}/ssh_host_ssh-falcon1024_key" 2>/dev/null || echo 0)"
    (( size > 0 )) && pass || fail "host key is empty"
fi

it "does not overwrite an existing host key"
if ! _have_keygen; then skip "OQS ssh-keygen not present"
else
    before_size="$(stat -c "%s" "${TEST_KEY_DIR}/ssh_host_ssh-falcon1024_key" 2>/dev/null)"
    _generate_host_key "ssh-falcon1024"
    after_size="$(stat -c "%s" "${TEST_KEY_DIR}/ssh_host_ssh-falcon1024_key" 2>/dev/null)"
    assert_eq "$before_size" "$after_size"
fi

# ── sshd_config generation ───────────────────────────────────────────────────

describe "sshd_config generation"

it "creates the config file at expected path"
_create_sshd_config "ssh-falcon1024"
assert_file_exists "${TEST_CONFIG_FILE}"

it "config contains the specified algorithm in HostKeyAlgorithms"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKeyAlgorithms ssh-falcon1024" "$content"

it "config contains PermitRootLogin no"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "PermitRootLogin no" "$content"

it "config contains StrictModes yes"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "StrictModes yes" "$content"

it "config contains AuthorizedKeysFile directive"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "AuthorizedKeysFile" "$content"

it "config references the correct PidFile path"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "PidFile ${TEST_PID_DIR}/sshd.pid" "$content"

it "sshd -t accepts the generated config (if sshd binary exists)"
if ! _have_sshd; then skip "sshd binary not present"
else
    # Only test syntax; sshd -t validates config without binding a port
    "${SBIN_DIR}/sshd" -t -f "${TEST_CONFIG_FILE}" &>/dev/null
    assert_zero $?
fi

# ── Systemd service file ──────────────────────────────────────────────────────

describe "systemd service file"

it "creates the service file"
_create_service_file
assert_file_exists "${TEST_SERVICE_FILE}"

it "service file contains [Unit] section"
content="$(cat "${TEST_SERVICE_FILE}")"
assert_contains "[Unit]" "$content"

it "service file contains [Service] section"
content="$(cat "${TEST_SERVICE_FILE}")"
assert_contains "[Service]" "$content"

it "service file contains [Install] section"
content="$(cat "${TEST_SERVICE_FILE}")"
assert_contains "[Install]" "$content"

it "ExecStart points to the OQS sshd binary"
content="$(cat "${TEST_SERVICE_FILE}")"
assert_contains "${SBIN_DIR}/sshd" "$content"

it "Restart=always is set"
content="$(cat "${TEST_SERVICE_FILE}")"
assert_contains "Restart=always" "$content"

# ── Algorithm coverage — single-algo ─────────────────────────────────────────

describe "algorithm coverage in config — single-algo"

it "config generation works for each individual supported algorithm"
all_ok=true
for algo in "${ALGORITHMS[@]}"; do
    _create_sshd_config "${algo}"
    content="$(cat "${TEST_CONFIG_FILE}")"
    if ! echo "$content" | grep -q "HostKeyAlgorithms ${algo}"; then
        all_ok=false; break
    fi
done
[[ "$all_ok" == true ]] && pass || fail "config missing algorithm: ${algo}"

# ── sshd_config generation — multi-algo ──────────────────────────────────────

describe "sshd_config generation — multi-algo"

_A1="ssh-falcon1024"
_A2="ssh-mldsa-65"
_A3="ssh-mldsa-44"

it "multi-algo config file is created"
_create_sshd_config "${_A1}" "${_A2}"
assert_file_exists "${TEST_CONFIG_FILE}"

it "multi-algo config has a HostKey line for the first algorithm"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_${_A1}_key" "$content"

it "multi-algo config has a HostKey line for the second algorithm"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_${_A2}_key" "$content"

it "multi-algo HostKeyAlgorithms contains both algorithms (comma-separated)"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKeyAlgorithms ${_A1},${_A2}" "$content"

it "multi-algo PubkeyAcceptedKeyTypes contains both algorithms"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "PubkeyAcceptedKeyTypes ${_A1},${_A2}" "$content"

it "multi-algo config still contains PermitRootLogin no"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "PermitRootLogin no" "$content"

it "three-algo config has exactly three HostKey lines"
_create_sshd_config "${_A1}" "${_A2}" "${_A3}"
count="$(grep -c "^HostKey " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "3" "$count"

it "three-algo HostKeyAlgorithms line contains all three algorithm names"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_line="$(echo "$content" | grep "^HostKeyAlgorithms")"
# all three must appear in the single HostKeyAlgorithms line
[[ "$hka_line" == *"${_A1}"* && "$hka_line" == *"${_A2}"* && "$hka_line" == *"${_A3}"* ]] \
    && pass || fail "HostKeyAlgorithms line does not contain all three algos: ${hka_line}"

it "full-suite config has one HostKey line per supported algorithm"
_create_sshd_config "${ALGORITHMS[@]}"
expected="${#ALGORITHMS[@]}"
actual="$(grep -c "^HostKey " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "$expected" "$actual"

it "full-suite HostKeyAlgorithms is a single comma-separated line"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_count="$(echo "$content" | grep -c "^HostKeyAlgorithms" || echo 0)"
assert_eq "1" "$hka_count"

it "sshd -t accepts multi-algo config (if sshd binary present)"
if ! _have_sshd; then skip "sshd binary not present"
else
    _create_sshd_config "${_A1}" "${_A2}"
    "${SBIN_DIR}/sshd" -t -f "${TEST_CONFIG_FILE}" &>/dev/null
    assert_zero $?
fi

# ── Hybrid mode — classical + PQ ─────────────────────────────────────────────

describe "hybrid config — classical key type mapping"

it "ed25519 maps to ssh-ed25519 in HostKeyAlgorithms"
_create_sshd_config "ed25519"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKeyAlgorithms ssh-ed25519" "$content"

it "ed25519 HostKey line uses the raw type name (ssh_host_ed25519_key)"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_ed25519_key" "$content"

it "rsa maps to rsa-sha2-512 and rsa-sha2-256 in HostKeyAlgorithms"
_create_sshd_config "rsa"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_line="$(echo "$content" | grep "^HostKeyAlgorithms")"
[[ "$hka_line" == *"rsa-sha2-512"* && "$hka_line" == *"rsa-sha2-256"* ]] \
    && pass || fail "HostKeyAlgorithms missing rsa entries: ${hka_line}"

it "rsa HostKey line uses the raw type name (ssh_host_rsa_key)"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_rsa_key" "$content"

describe "hybrid config — mixed classical + PQ"

it "hybrid config is created for ed25519 + PQ algorithm"
_create_sshd_config "ed25519" "${_A1}"
assert_file_exists "${TEST_CONFIG_FILE}"

it "hybrid config has HostKey line for ed25519"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_ed25519_key" "$content"

it "hybrid config has HostKey line for the PQ algorithm"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "HostKey ${TEST_KEY_DIR}/ssh_host_${_A1}_key" "$content"

it "hybrid HostKeyAlgorithms contains ssh-ed25519"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_line="$(echo "$content" | grep "^HostKeyAlgorithms")"
[[ "$hka_line" == *"ssh-ed25519"* ]] \
    && pass || fail "HostKeyAlgorithms missing ssh-ed25519: ${hka_line}"

it "hybrid HostKeyAlgorithms contains the PQ algorithm"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_line="$(echo "$content" | grep "^HostKeyAlgorithms")"
[[ "$hka_line" == *"${_A1}"* ]] \
    && pass || fail "HostKeyAlgorithms missing ${_A1}: ${hka_line}"

it "hybrid HostKeyAlgorithms is exactly one line"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_count="$(echo "$content" | grep -c "^HostKeyAlgorithms" || echo 0)"
assert_eq "1" "$hka_count"

it "full hybrid config (all classical + all PQ) has correct HostKey count"
_create_sshd_config "${CLASSICAL_KEYTYPES[@]}" "${ALGORITHMS[@]}"
expected=$(( ${#CLASSICAL_KEYTYPES[@]} + ${#ALGORITHMS[@]} ))
actual="$(grep -c "^HostKey " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "$expected" "$actual"

it "full hybrid HostKeyAlgorithms is exactly one line"
content="$(cat "${TEST_CONFIG_FILE}")"
hka_count="$(echo "$content" | grep -c "^HostKeyAlgorithms" || echo 0)"
assert_eq "1" "$hka_count"

it "full hybrid config still contains PermitRootLogin no"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "PermitRootLogin no" "$content"

# ── KexAlgorithms — PQ-only mode ──────────────────────────────────────────────

describe "KexAlgorithms — PQ-only config"

it "PQ-only config contains a KexAlgorithms directive"
_create_sshd_config "${_A1}"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "KexAlgorithms" "$content"

it "PQ-only KexAlgorithms is exactly one line"
kex_count="$(grep -c "^KexAlgorithms " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "1" "$kex_count"

it "PQ-only KexAlgorithms contains a hybrid ML-KEM algorithm"
kex_line="$(grep "^KexAlgorithms " "${TEST_CONFIG_FILE}")"
[[ "$kex_line" == *"mlkem"* ]] \
    && pass || fail "KexAlgorithms missing ML-KEM algorithm: ${kex_line}"

it "PQ-only KexAlgorithms does not include the classical-only curve25519-sha256"
kex_line="$(grep "^KexAlgorithms " "${TEST_CONFIG_FILE}")"
# curve25519-sha256 is a classical-only KEX; only present in hybrid mode
[[ "$kex_line" != *"curve25519-sha256,"* && "$kex_line" != *",curve25519-sha256"* ]] \
    && pass || fail "PQ-only KexAlgorithms unexpectedly contains curve25519-sha256"

it "full PQ-only suite config has exactly one KexAlgorithms line"
_create_sshd_config "${ALGORITHMS[@]}"
kex_count="$(grep -c "^KexAlgorithms " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "1" "$kex_count"

# ── KexAlgorithms — hybrid mode ───────────────────────────────────────────────

describe "KexAlgorithms — hybrid config"

it "hybrid config contains a KexAlgorithms directive"
_create_sshd_config "ed25519" "${_A1}"
content="$(cat "${TEST_CONFIG_FILE}")"
assert_contains "KexAlgorithms" "$content"

it "hybrid KexAlgorithms contains a ML-KEM algorithm"
kex_line="$(grep "^KexAlgorithms " "${TEST_CONFIG_FILE}")"
[[ "$kex_line" == *"mlkem"* ]] \
    && pass || fail "hybrid KexAlgorithms missing ML-KEM algorithm: ${kex_line}"

it "hybrid KexAlgorithms contains classical fallback curve25519-sha256"
kex_line="$(grep "^KexAlgorithms " "${TEST_CONFIG_FILE}")"
[[ "$kex_line" == *"curve25519-sha256"* ]] \
    && pass || fail "hybrid KexAlgorithms missing curve25519-sha256: ${kex_line}"

it "hybrid KexAlgorithms is exactly one line"
kex_count="$(grep -c "^KexAlgorithms " "${TEST_CONFIG_FILE}" 2>/dev/null || echo 0)"
assert_eq "1" "$kex_count"

it "PQ KEX algorithms appear before classical KEX in hybrid config"
kex_line="$(grep "^KexAlgorithms " "${TEST_CONFIG_FILE}")"
kex_val="${kex_line#KexAlgorithms }"
# First entry must be one of the PQ KEX algorithms (contains 'mlkem')
first_algo="${kex_val%%,*}"
[[ "$first_algo" == *"mlkem"* ]] \
    && pass || fail "PQ KEX not first in KexAlgorithms: first was '${first_algo}'"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
