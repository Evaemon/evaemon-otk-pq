#!/bin/bash
# Unit tests for client/backup.sh (do_backup / do_restore)
#
# No network required.  All tests operate on temporary directories so the
# real ~/.ssh is never touched.  Tests that require openssl are skipped
# automatically when it is absent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

source "${SCRIPT_DIR}/../test_runner.sh"

# Isolated scratch area — cleaned up on exit
WORK_DIR="$(mktemp -d)"
WORK_SSH="${WORK_DIR}/.ssh"
mkdir -p "${WORK_SSH}"
chmod 700 "${WORK_SSH}"
trap 'rm -rf "${WORK_DIR}"' EXIT

_have_openssl() { command -v openssl &>/dev/null; }

# Source backup.sh for its functions.  The BASH_SOURCE guard prevents main()
# from auto-running.  backup.sh enables set -eo pipefail internally so we
# disable that afterward to keep the test harness working.
source "${PROJECT_ROOT}/client/backup.sh" 2>/dev/null
set +eo pipefail

# Override SSH_DIR to our isolated directory for all test calls.
SSH_DIR="${WORK_SSH}"

# ── do_backup — empty directory ───────────────────────────────────────────────

describe "do_backup — empty key directory"

it "exits 0 (graceful no-op) when no PQ keys exist"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${WORK_SSH}" do_backup "${WORK_DIR}/empty_backup.enc" <<< $'pw\npw') \
        2>/dev/null || rc=$?
    assert_zero $rc
fi

it "emits a 'nothing to back up' warning when no keys exist"
if ! _have_openssl; then skip "openssl not available"; else
    out=$(SSH_DIR="${WORK_SSH}" do_backup "${WORK_DIR}/empty2.enc" <<< $'pw\npw' 2>&1 || true)
    echo "$out" | grep -qi "nothing\|no post-quantum" \
        && pass || fail "expected 'nothing to back up' message; got: ${out}"
fi

# ── Plant fake key pair ───────────────────────────────────────────────────────

_PRIV="${WORK_SSH}/id_ssh-falcon1024"
_PUB="${WORK_SSH}/id_ssh-falcon1024.pub"
printf 'FAKE_PRIVATE_KEY_MATERIAL\n' > "${_PRIV}"
printf 'ssh-falcon1024 FAKEBASE64CONTENT testkey\n' > "${_PUB}"
chmod 600 "${_PRIV}"
chmod 644 "${_PUB}"
_DEST="${WORK_DIR}/test_backup.tar.gz.enc"

# ── do_backup — with keys present ────────────────────────────────────────────

describe "do_backup — with keys present"

it "do_backup exits 0 when keys are present"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${WORK_SSH}" do_backup "${_DEST}" <<< $'testpass\ntestpass') \
        2>/dev/null || rc=$?
    assert_zero $rc
fi

it "do_backup creates the archive file at the specified path"
if ! _have_openssl; then skip "openssl not available"; else
    assert_file_exists "${_DEST}"
fi

it "archive has permissions 600"
if ! _have_openssl; then skip "openssl not available"; else
    assert_file_perms "600" "${_DEST}"
fi

it "archive is non-empty"
if ! _have_openssl; then skip "openssl not available"; else
    sz="$(stat -c "%s" "${_DEST}" 2>/dev/null || echo 0)"
    (( sz > 0 )) && pass || fail "backup archive is 0 bytes"
fi

# ── do_restore — roundtrip ────────────────────────────────────────────────────

describe "do_restore — roundtrip"

_RESTORE_DIR="${WORK_DIR}/restore_ssh"
mkdir -p "${_RESTORE_DIR}"
chmod 700 "${_RESTORE_DIR}"

it "do_restore exits 0 with correct passphrase"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${_RESTORE_DIR}" do_restore "${_DEST}" <<< 'testpass') \
        2>/dev/null || rc=$?
    assert_zero $rc
fi

it "do_restore creates the private key file in SSH_DIR"
if ! _have_openssl; then skip "openssl not available"; else
    assert_file_exists "${_RESTORE_DIR}/id_ssh-falcon1024"
fi

it "restored private key content matches original"
if ! _have_openssl; then skip "openssl not available"; else
    content="$(cat "${_RESTORE_DIR}/id_ssh-falcon1024" 2>/dev/null || echo "")"
    assert_contains "FAKE_PRIVATE_KEY_MATERIAL" "$content"
fi

it "sets 600 permissions on restored private key"
if ! _have_openssl; then skip "openssl not available"; else
    assert_file_perms "600" "${_RESTORE_DIR}/id_ssh-falcon1024"
fi

# ── do_restore — wrong passphrase ────────────────────────────────────────────

describe "do_restore — wrong passphrase"

it "exits non-zero when the passphrase is wrong"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${_RESTORE_DIR}" do_restore "${_DEST}" <<< 'wrongpassword') \
        2>/dev/null || rc=$?
    assert_nonzero $rc
fi

# ── do_backup — passphrase validation ────────────────────────────────────────

describe "do_backup — passphrase validation"

it "rejects mismatched passphrases"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${WORK_SSH}" do_backup "${WORK_DIR}/mismatch.enc" <<< $'passA\npassB') \
        2>/dev/null || rc=$?
    assert_nonzero $rc
fi

it "rejects an empty passphrase"
if ! _have_openssl; then skip "openssl not available"; else
    rc=0
    (SSH_DIR="${WORK_SSH}" do_backup "${WORK_DIR}/empty_pass.enc" <<< $'\n\n') \
        2>/dev/null || rc=$?
    assert_nonzero $rc
fi

# ── Done ─────────────────────────────────────────────────────────────────────
test_summary
