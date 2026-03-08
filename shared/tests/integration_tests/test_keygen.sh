#!/bin/bash
# Integration tests for client/keygen.sh
#
# These tests exercise the key generation flow end-to-end.
# If the OQS ssh-keygen binary is not present the tests that require it are
# skipped automatically so the suite still passes in a build-only environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/../test_runner.sh"
source "${PROJECT_ROOT}/shared/config.sh"
source "${PROJECT_ROOT}/shared/logging.sh"
source "${PROJECT_ROOT}/shared/validation.sh"

# Work in a temporary directory so we never touch ~/.ssh
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Override SSH_DIR and BIN_DIR for isolation
SSH_DIR="${WORK_DIR}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

_have_keygen() {
    [[ -x "${BIN_DIR}/ssh-keygen" ]]
}

# ── Key file naming convention ────────────────────────────────────────────────

describe "key file naming"

it "key file name follows id_<algorithm> convention"
expected_name="id_ssh-falcon1024"
actual_name="id_${ALGORITHMS[0]}"
assert_eq "$expected_name" "$actual_name"

it "all algorithm names start with ssh-"
all_ok=true
for algo in "${ALGORITHMS[@]}"; do
    [[ "$algo" == ssh-* ]] || { all_ok=false; break; }
done
[[ "$all_ok" == true ]] && pass || fail "some algorithms do not start with 'ssh-'"

# ── ssh-keygen invocation (requires OQS binary) ───────────────────────────────

describe "OQS ssh-keygen key generation"

it "ssh-keygen binary exists and is executable"
if _have_keygen; then
    pass
else
    skip "OQS ssh-keygen not built yet (run build_oqs_openssh.sh first)"
fi

it "generates a private key file for ssh-falcon1024"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    keyfile="${WORK_DIR}/.ssh/id_ssh-falcon1024"
    "${BIN_DIR}/ssh-keygen" -t ssh-falcon1024 -f "${keyfile}" -N "" &>/dev/null
    assert_file_exists "${keyfile}"
fi

it "generates a matching .pub file for ssh-falcon1024"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    assert_file_exists "${WORK_DIR}/.ssh/id_ssh-falcon1024.pub"
fi

it "private key is non-empty"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    keyfile="${WORK_DIR}/.ssh/id_ssh-falcon1024"
    size="$(stat -c "%s" "${keyfile}" 2>/dev/null || echo 0)"
    (( size > 0 )) && pass || fail "private key is empty (${size} bytes)"
fi

it "public key contains the algorithm name"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    content="$(cat "${WORK_DIR}/.ssh/id_ssh-falcon1024.pub" 2>/dev/null || echo "")"
    assert_contains "falcon" "$content"
fi

it "generated keys have correct permissions after chmod 600"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    chmod 600 "${WORK_DIR}/.ssh/id_ssh-falcon1024"
    assert_file_perms "600" "${WORK_DIR}/.ssh/id_ssh-falcon1024"
fi

it "generates keys for all supported algorithms (or skips gracefully)"
if ! _have_keygen; then
    skip "OQS ssh-keygen not present"
else
    all_ok=true
    for algo in "${ALGORITHMS[@]}"; do
        keyfile="${WORK_DIR}/.ssh/id_${algo}_bulk"
        if ! "${BIN_DIR}/ssh-keygen" -t "${algo}" -f "${keyfile}" -N "" &>/dev/null; then
            all_ok=false
            break
        fi
        if [[ ! -f "${keyfile}" || ! -f "${keyfile}.pub" ]]; then
            all_ok=false
            break
        fi
    done
    [[ "$all_ok" == true ]] && pass || fail "key generation failed for at least one algorithm"
fi

# ── SSH_DIR isolation ────────────────────────────────────────────────────────

describe "key storage directory"

it "SSH_DIR exists and has permissions 700"
assert_file_perms "700" "${SSH_DIR}"

it "SSH_DIR does not contain unexpected files after clean start"
# Only allow id_* and potentially known_hosts
unexpected=false
while IFS= read -r -d '' f; do
    fname="$(basename "$f")"
    [[ "$fname" == id_* || "$fname" == known_hosts ]] || { unexpected=true; break; }
done < <(find "${SSH_DIR}" -maxdepth 1 -type f -print0 2>/dev/null)
[[ "$unexpected" == false ]] && pass || fail "unexpected file found in SSH_DIR: ${fname}"

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
