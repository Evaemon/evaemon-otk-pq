# Usage Manual — Evaemon OTK-PQ

This manual covers every tool in Evaemon OTK-PQ: what it does, when to use it, and how to invoke it both via the interactive wizard and directly from the command line.

---

## Table of Contents

1. [Wizard quick-reference](#wizard-quick-reference)
2. [OTK-PQ tools](#otk-pq-tools)
3. [Client tools](#client-tools)
4. [Server tools](#server-tools)
5. [Shared / configuration](#shared--configuration)
6. [Running the test suite](#running-the-test-suite)

---

## Wizard quick-reference

```bash
sudo bash wizard.sh
```

The wizard opens with the EVAEMON ASCII logo splash, then presents a dark cyan-themed whiptail interface.

### Mode selection

| Input | Mode |
|-------|------|
| `1` | Server |
| `2` | Client |
| `3` | Exit |

### Server menu

| Input | Action |
|-------|--------|
| `1` | Build / Rebuild OQS-OpenSSH |
| `2` | Configure sshd |
| `3` | Monitor sshd |
| `4` | Update / Rebuild |
| `5` | PQ-Only Test Mode |
| `6` | Diagnostics |
| `7` | **OTK-PQ Setup & Management** |
| `8` | Back to Main Menu |
| `9` | Exit |

### OTK-PQ Server submenu (option 7)

| Input | Action |
|-------|--------|
| `1` | Setup OTK-PQ Server |
| `2` | Enroll Client Master Key |
| `3` | List Enrolled Clients |
| `4` | Revoke Client |
| `5` | Revocation Ledger Statistics |
| `6` | Prune Revocation Ledger |
| `7` | Back |

### Client menu

| Input | Action |
|-------|--------|
| `1` | Build / Rebuild OQS-OpenSSH |
| `2` | Generate key pair |
| `3` | Copy public key to server |
| `4` | Connect to server (standard PQ) |
| `5` | Backup / Restore keys |
| `6` | Health check |
| `7` | Rotate keys |
| `8` | Migrate Classical Keys to PQ |
| `9` | **OTK-PQ — One-Time Key Connect** |
| `10` | Debug tools |
| `11` | Performance benchmark |
| `12` | Back to Main Menu |
| `13` | Exit |

### OTK-PQ Client submenu (option 9)

| Input | Action |
|-------|--------|
| `1` | Generate Master Key |
| `2` | Master Key Info |
| `3` | Verify Master Key |
| `4` | Export Master Public Key |
| `5` | OTK Connect (one-time session) |
| `6` | Cleanup Stale Sessions |
| `7` | Rotate Master Key |
| `8` | Back |

---

## OTK-PQ tools

### Master Key Manager (`client/otk/master_key.sh`)

Manages the Layer 1 ML-DSA-87 master key — the root of trust that never leaves the client.

```bash
# Generate a new master key pair
bash client/otk/master_key.sh generate

# Generate with passphrase protection (prompted interactively)
bash client/otk/master_key.sh generate

# Verify master key integrity and permissions
bash client/otk/master_key.sh verify

# Display master key metadata (fingerprint, algorithm, age)
bash client/otk/master_key.sh info

# Export master public key for server enrollment
bash client/otk/master_key.sh export

# Rotate master key (archives old, generates new)
bash client/otk/master_key.sh rotate
```

**Key files:**
- Private key: `~/.ssh/otk/master/otk_master_sign` (permissions 600)
- Public key: `~/.ssh/otk/master/otk_master_sign.pub` (permissions 644)
- Creation timestamp: `~/.ssh/otk/master/.master_created`

**Master key rotation:** after rotating, all servers must re-enroll the new public key. The old key is archived in `~/.ssh/otk/master/archive/<timestamp>/`.

---

### Session Key Engine (`client/otk/session_key.sh`)

Generates fresh hybrid session key pairs for Layer 2 — called automatically by `otk_connect.sh`.

```bash
# Generate a session key pair (usually called automatically)
bash client/otk/session_key.sh generate

# List active (undestroyed) session bundles
bash client/otk/session_key.sh list
```

Each session bundle contains:
- `session_key` / `session_key.pub` — ephemeral Ed25519 key pair
- `session_pq_key` / `session_pq_key.pub` — ephemeral PQ key pair
- `master_signature` — ML-DSA-87 signature over session public keys
- `nonce` — timestamp + random (replay prevention)
- `session_id` — SHA3-256 hash of nonce + public keys

Session bundles are stored in `~/.ssh/otk/sessions/` and destroyed after use.

---

### OTK Lifecycle Manager (`client/otk/otk_lifecycle.sh`)

Manages Layer 3 — secure destruction and one-time enforcement.

```bash
# Destroy a specific session bundle
bash client/otk/otk_lifecycle.sh destroy <bundle_dir>

# Verify destruction is complete (no residual material)
bash client/otk/otk_lifecycle.sh verify <bundle_dir>

# Cleanup all stale session bundles (from crashed connections)
bash client/otk/otk_lifecycle.sh cleanup
```

**Secure destruction:** uses `shred` (multi-pass overwrite + zero pass + unlink) when available, falls back to manual overwrite with random data. Configurable via `OTK_SHRED_PASSES` (default: 3).

---

### OTK Connect (`client/otk/otk_connect.sh`)

The full OTK-PQ connection flow — orchestrates all three layers.

```bash
# Interactive mode (prompts for host, user, port)
bash client/otk/otk_connect.sh

# Direct mode
bash client/otk/otk_connect.sh server_host username [port]
```

**Connection lifecycle:**

| Phase | Layer | What happens |
|-------|-------|-------------|
| Pre-connect | Layer 2 | Generate fresh hybrid key pair, sign with master key |
| Connect | Layer 1+2 | Push session bundle, verify on server, SSH with ephemeral key |
| Post-connect | Layer 3 | Mark used, destroy all key material, verify destruction |

**Requirements:**
- Master key must exist (`client/otk/master_key.sh generate`)
- Master key must be enrolled on the server
- An existing PQ or classical key must be available for the bootstrap connection (to push the session bundle)

---

### OTK Server (`server/otk/otk_server.sh`)

Server-side enrollment, verification, and management.

```bash
# Initialize OTK-PQ server (creates directories, ledger)
bash server/otk/otk_server.sh setup

# Enroll a client's master public key
bash server/otk/otk_server.sh enroll <client_name> [pubkey_file]

# List all enrolled clients
bash server/otk/otk_server.sh list

# Revoke a client's enrollment
bash server/otk/otk_server.sh revoke <client_name>

# Verify a session bundle
bash server/otk/otk_server.sh verify <bundle_dir> [client_name]

# Revocation ledger operations
bash server/otk/otk_server.sh ledger stats
bash server/otk/otk_server.sh ledger prune
```

**Important:** The server only stores master *public* keys. If the server is compromised, the attacker cannot forge session keys because they lack the client's master private key.

---

### Revocation Ledger (`server/otk/revocation_ledger.sh`)

Server-side record of used session keys. Prevents replay attacks.

```bash
# Add a session key hash to the ledger
bash server/otk/revocation_ledger.sh add <session_id>

# Check if a session key is revoked
bash server/otk/revocation_ledger.sh check <session_id>

# Prune expired entries (older than OTK_LEDGER_PRUNE_DAYS)
bash server/otk/revocation_ledger.sh prune

# Display ledger statistics
bash server/otk/revocation_ledger.sh stats

# Initialize the ledger
bash server/otk/revocation_ledger.sh init
```

**Format:** each line is `TIMESTAMP SESSION_ID_HASH`. Entries older than `OTK_LEDGER_PRUNE_DAYS` (default 7) are pruned. File-level locking (flock) prevents corruption from concurrent sessions.

---

## Client tools

### Key generation (`client/keygen.sh`)

Generates a PQ or classical SSH key pair. Used for the standard PQ connection mode and as the bootstrap key for OTK-PQ.

```bash
bash client/keygen.sh
```

### Copy key to server (`client/copy_key_to_server.sh`)

Appends your public key to the server's `~/.ssh/authorized_keys`.

```bash
bash client/copy_key_to_server.sh
```

### Connect (`client/connect.sh`)

Standard PQ SSH connection (without OTK — persistent key). Use `client/otk/otk_connect.sh` for one-time key connections.

```bash
bash client/connect.sh
```

### Backup / Restore (`client/backup.sh`)

AES-256-CBC encrypted backup of all SSH key pairs.

```bash
bash client/backup.sh backup /path/to/output.tar.gz.enc
bash client/backup.sh restore /path/to/backup.tar.gz.enc
```

### Health check (`client/health_check.sh`)

Five-stage connectivity and authentication check with exponential backoff retry.

```bash
bash client/health_check.sh
```

### Key rotation (`client/key_rotation.sh`)

Safe key rotation with verification that the old key is rejected.

```bash
bash client/key_rotation.sh
```

### Key migration (`client/migrate_keys.sh`)

Scans for classical keys and offers to migrate them to post-quantum.

```bash
bash client/migrate_keys.sh
```

### Debug (`client/tools/debug.sh`)

Verbose diagnostics and `-vvv` SSH session log.

```bash
bash client/tools/debug.sh
```

### Performance benchmark (`client/tools/performance_test.sh`)

Keygen time, key sizes, and handshake latency across algorithms.

```bash
bash client/tools/performance_test.sh
```

---

## Server tools

### Server setup (`server/server.sh`)

Configures sshd with PQ host keys, algorithm selection, and systemd service.

```bash
sudo bash server/server.sh
```

### Monitor (`server/monitoring.sh`)

Real-time sshd status with quantum readiness report.

```bash
sudo bash server/monitoring.sh
```

### Update / Rebuild (`server/update.sh`)

Controlled in-place upgrade of the OQS-OpenSSH stack.

```bash
sudo bash server/update.sh
```

### PQ-Only Test Mode (`server/pq_only_testmode.sh`)

Pure post-quantum sshd that rejects all classical algorithms.

```bash
sudo bash server/pq_only_testmode.sh
```

### Diagnostics (`server/tools/diagnostics.sh`)

Server health report: binary versions, sshd_config, host key fingerprints, port conflicts.

```bash
sudo bash server/tools/diagnostics.sh
```

---

## Shared / configuration

### `shared/config.sh` — Base configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_DIR` | `<repo>/build` | Root of all build output |
| `BIN_DIR` | `<repo>/build/bin` | OQS SSH client binaries |
| `ALGORITHMS` | (array, 12 entries) | Supported PQ authentication algorithms |
| `KEX_ALGORITHMS` | (array, 5 entries) | PQ/hybrid KEX algorithms |

### `shared/otk_config.sh` — OTK-PQ configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OTK_MASTER_SIGN_ALGO` | `ssh-mldsa-87` | Master key algorithm (ML-DSA-87) |
| `OTK_MASTER_KEM_ALGO` | `mlkem1024-sha384` | Master KEM algorithm (ML-KEM-1024) |
| `OTK_NONCE_MAX_AGE` | `300` | Max nonce age in seconds |
| `OTK_NONCE_RANDOM_BYTES` | `32` | Nonce random component size |
| `OTK_LEDGER_PRUNE_DAYS` | `7` | Ledger entry expiration |
| `OTK_LEDGER_MAX_ENTRIES` | `100000` | Max ledger size before forced prune |
| `OTK_SHRED_PASSES` | `3` | Secure deletion overwrite passes |
| `OTK_MASTER_MAX_AGE_DAYS` | `365` | Master key rotation recommendation |

### Log verbosity (`shared/logging.sh`)

```bash
export LOG_LEVEL=0   # DEBUG
export LOG_LEVEL=1   # INFO (default)
export LOG_LEVEL=2   # WARN
export LOG_LEVEL=3   # ERROR
```

---

## Running the test suite

### OTK-PQ tests (103 assertions, no OQS binary required)

```bash
bash shared/tests/unit_tests/test_otk_config.sh              # 33 — config values
bash shared/tests/unit_tests/test_otk_session_key.sh         # 18 — nonces, session IDs
bash shared/tests/unit_tests/test_otk_lifecycle.sh           # 17 — destruction, verification
bash shared/tests/unit_tests/test_otk_master_key.sh          # 15 — master key management
bash shared/tests/unit_tests/test_otk_revocation_ledger.sh   # 20 — ledger, replay prevention
```

### Base unit tests (no OQS binary required)

```bash
bash shared/tests/unit_tests/test_validation.sh    # 44 — input validation
bash shared/tests/unit_tests/test_logging.sh       # 26 — log levels, log_success
bash shared/tests/unit_tests/test_functions.sh     # 13 — retry_with_backoff
bash shared/tests/unit_tests/test_backup.sh        # 13 — backup/restore
bash shared/tests/unit_tests/test_copy_key.sh      # 10 — copy_client_key
bash shared/tests/unit_tests/test_connect.sh       # 15 — connect() args
bash shared/tests/unit_tests/test_migrate_keys.sh  # 16 — classical key detection
bash shared/tests/unit_tests/test_key_age.sh       #  6 — rotation policy
bash shared/tests/unit_tests/test_monitoring.sh    # 10 — quantum readiness
```

### Integration tests (auto-skip if OQS absent)

```bash
bash shared/tests/integration_tests/test_keygen.sh       # 11 — key generation
bash shared/tests/integration_tests/test_server.sh       # 53 — sshd_config
bash shared/tests/integration_tests/test_key_rotation.sh  # 14 — rotation
```

Exit code 0 = all tests passed. Full suite: **334+ tests**.
