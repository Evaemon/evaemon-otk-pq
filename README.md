# Evaemon OTK-PQ

> *"Use it once. Then it no longer exists."*

Evaemon OTK-PQ is a **One-Time Key Post-Quantum Hybrid Authentication** system for SSH. It introduces a fundamentally new approach where **every session requires a unique, single-use key that is cryptographically destroyed after use**. Even if an attacker intercepts a session key, it is already worthless.

Built on top of the [Evaemon](https://github.com/Yarpii/Evaemon) post-quantum SSH toolkit (OQS-OpenSSH), OTK-PQ adds a three-layer architecture that ensures nothing persists.

---

## Quick start

```bash
git clone https://github.com/Evaemon/evaemon-otk-pq.git
cd evaemon-otk-pq
sudo bash wizard.sh
```

The wizard guides you through building OQS-OpenSSH, setting up OTK-PQ master keys, enrolling clients, and connecting with one-time session keys.

---

## The Problem

Traditional SSH authentication relies on persistent key pairs. The same private key authenticates the user indefinitely. This creates:

- A stolen private key grants unlimited access until manually revoked
- Key reuse across sessions creates a large attack surface over time
- Quantum computers threaten to break classical key exchange retroactively
- No forward secrecy at the authentication layer

## The OTK-PQ Solution

OTK-PQ separates authentication into three distinct, independent layers:

```
┌─────────────────────────────────────────────────────┐
│  LAYER 1 — POST-QUANTUM MASTER KEY (Anchor)         │
│  ─────────────────────────────────────────────────── │
│  • Never transmitted over the network                │
│  • Exists only on client                             │
│  • Signs ephemeral session keys to prove legitimacy  │
│  • ML-DSA-87 (FIPS 204) — NIST Level 5              │
│  • The root of trust                                 │
└──────────────────────┬──────────────────────────────┘
                       │ validates
┌──────────────────────▼──────────────────────────────┐
│  LAYER 2 — HYBRID SESSION KEY GENERATION             │
│  ─────────────────────────────────────────────────── │
│  • Fresh key pair generated for every session        │
│  • Hybrid: Ed25519 + ML-DSA-87 combined              │
│  • Both must be valid — if one is broken, the other  │
│    still protects                                    │
│  • Signed by the master key                          │
└──────────────────────┬──────────────────────────────┘
                       │ authenticates
┌──────────────────────▼──────────────────────────────┐
│  LAYER 3 — ONE-TIME EXECUTION & DESTRUCTION          │
│  ─────────────────────────────────────────────────── │
│  • Session key used exactly once                     │
│  • After session: cryptographically destroyed         │
│  • Revocation ledger — used keys can never be        │
│    replayed                                          │
│  • No persistent session material remains            │
└─────────────────────────────────────────────────────┘
```

---

## Features

### OTK-PQ (One-Time Key)
- **Three-layer architecture** — master key anchor, hybrid session keys, one-time destruction
- **Per-session ephemeral keys** — fresh hybrid key pair generated and destroyed every connection
- **Master key signing** — ML-DSA-87 (FIPS 204, Level 5) signs session keys; master key never on the wire
- **Revocation ledger** — server-side record prevents replay attacks; used keys can never be reused
- **Secure destruction** — multi-pass overwrite (shred) with verification of complete erasure
- **Nonce validation** — timestamp + CSPRNG prevents replay and ensures temporal isolation
- **Client enrollment** — server stores only master public keys; server compromise doesn't expose private keys
- **Master key rotation** — archival and re-enrollment when rotating master keys
- **Stale session cleanup** — automatic cleanup of interrupted or crashed sessions

### Base PQ SSH (from Evaemon Core)
- **12 post-quantum algorithms** — Falcon, ML-DSA, SPHINCS+, SLH-DSA, MAYO
- **5 hybrid KEX algorithms** — ML-KEM (Kyber) + classical key exchange
- **Hybrid mode** — classical (Ed25519, RSA) alongside PQ algorithms
- **Non-invasive** — runs a separate sshd; system OpenSSH is never modified
- **Interactive wizard** — dark cyan-on-black whiptail GUI with OTK-PQ submenus
- **Client tools** — keygen, connect, backup/restore, health check, rotation, migration, debug, benchmark
- **Server tools** — setup, monitoring, update/rebuild, diagnostics

---

## Algorithms

| Purpose | Algorithm | Standard | Security |
|---------|-----------|----------|----------|
| Master key signing | ML-DSA-87 (Dilithium) | FIPS 204 | Level 5 |
| Master key encapsulation | ML-KEM-1024 (Kyber) | FIPS 203 | Level 5 |
| Session classical signing | Ed25519 | RFC 8032 | — |
| Session classical KEX | X25519 / Curve25519 | RFC 7748 | — |
| Session PQ KEX | ML-KEM-1024 hybrid | FIPS 203 | Level 5 |
| Session KDF | HKDF-SHA-512 | RFC 5869 | — |
| Nonce generation | CSPRNG + timestamp | — | — |
| Revocation hashing | SHA3-256 | FIPS 202 | — |

Plus 12 PQ authentication algorithms and 5 hybrid KEX algorithms inherited from Evaemon Core — see [docs/security.md](docs/security.md).

---

## How It Works

### 1. Initial Setup (One-Time)

```bash
# Client: Generate OTK-PQ master key
sudo bash client/otk/master_key.sh generate

# Client: Export master public key for enrollment
bash client/otk/master_key.sh export > my_master.pub

# Server: Setup OTK-PQ server
sudo bash server/otk/otk_server.sh setup

# Server: Enroll client's master public key
sudo bash server/otk/otk_server.sh enroll alice my_master.pub
```

### 2. Every Connection (Automatic)

```bash
# OTK Connect handles the full lifecycle:
bash client/otk/otk_connect.sh server_host username [port]
```

What happens under the hood:

1. **Generate** — fresh hybrid key pair (Ed25519 + ML-DSA-87), signed by master key
2. **Push** — session bundle (public keys + signature + nonce) sent to server
3. **Verify** — server checks revocation ledger, validates nonce, verifies master signature
4. **Connect** — SSH session established with ephemeral key and hybrid PQ KEX
5. **Destroy** — all session key material securely wiped on both sides
6. **Revoke** — session key hash added to revocation ledger (can never be replayed)

### 3. Result

The session key **ceases to exist**. It cannot be reconstructed. Any attempt to replay it is rejected.

---

## Security Properties

| Property | Traditional SSH | OTK-PQ |
|----------|----------------|--------|
| Key reuse | Same key indefinitely | Never — one key per session |
| Forward secrecy | Session-level only | Authentication + session level |
| Quantum resistance | None (RSA/Ed25519) | Hybrid classical + post-quantum |
| Stolen key impact | Full access until revoked | Zero — key already expired |
| Replay attacks | Possible if key stolen | Impossible — revocation ledger |
| Master key exposure | Key is the auth key | Master key never on the wire |
| Attack surface | Persistent | Ephemeral — exists only during session |

---

## Project Structure

```
evaemon-otk-pq/
├── wizard.sh                              # Interactive entry point
├── build_oqs_openssh.sh                   # Builds liboqs + OQS-OpenSSH from source
├── OTK-PQ .md                             # OTK-PQ architecture specification
│
├── client/
│   ├── otk/                               # ── OTK-PQ Client ──
│   │   ├── master_key.sh                  # Layer 1: ML-DSA-87 master key manager
│   │   ├── session_key.sh                 # Layer 2: Hybrid session key engine
│   │   ├── otk_lifecycle.sh               # Layer 3: Secure destruction & lifecycle
│   │   └── otk_connect.sh                 # Full OTK connection orchestrator
│   ├── keygen.sh                          # PQ/classical key generation
│   ├── copy_key_to_server.sh              # Push public key to server
│   ├── connect.sh                         # Standard PQ SSH connection
│   ├── backup.sh                          # AES-256 encrypted key backup/restore
│   ├── health_check.sh                    # Five-stage connectivity check
│   ├── key_rotation.sh                    # Safe key rotation with verification
│   ├── migrate_keys.sh                    # Classical → PQ key migration
│   └── tools/
│       ├── debug.sh                       # Verbose diagnostics
│       └── performance_test.sh            # Algorithm benchmarks
│
├── server/
│   ├── otk/                               # ── OTK-PQ Server ──
│   │   ├── otk_server.sh                  # Enrollment, verification, management
│   │   └── revocation_ledger.sh           # Replay prevention ledger
│   ├── server.sh                          # Server setup (host keys, sshd_config)
│   ├── monitoring.sh                      # Service monitoring
│   ├── update.sh                          # Rebuild & restart
│   ├── pq_only_testmode.sh               # Pure PQ test mode
│   └── tools/
│       └── diagnostics.sh                 # Server diagnostics
│
├── shared/
│   ├── config.sh                          # Base configuration (algorithms, paths)
│   ├── otk_config.sh                      # OTK-PQ configuration (Layer 1-3 params)
│   ├── logging.sh                         # Structured logging
│   ├── validation.sh                      # Input validation
│   ├── functions.sh                       # Shared helpers
│   └── tests/
│       ├── test_runner.sh                 # Bash test harness
│       ├── unit_tests/
│       │   ├── test_otk_config.sh         # 33 tests — OTK config values
│       │   ├── test_otk_session_key.sh    # 18 tests — nonces, session IDs
│       │   ├── test_otk_lifecycle.sh      # 17 tests — destruction, verification
│       │   ├── test_otk_master_key.sh     # 15 tests — master key management
│       │   ├── test_otk_revocation_ledger.sh # 20 tests — ledger, replay prevention
│       │   ├── test_validation.sh         # 44 tests — input validation
│       │   ├── test_logging.sh            # 26 tests — log levels
│       │   ├── test_functions.sh          # 13 tests — retry helpers
│       │   ├── test_backup.sh             # 13 tests — backup/restore
│       │   ├── test_copy_key.sh           # 10 tests — key copy
│       │   ├── test_connect.sh            # 15 tests — connection args
│       │   ├── test_migrate_keys.sh       # 16 tests — key migration
│       │   ├── test_key_age.sh            #  6 tests — rotation policy
│       │   └── test_monitoring.sh         # 10 tests — monitoring
│       └── integration_tests/
│           ├── test_keygen.sh             # 11 tests — key generation
│           ├── test_server.sh             # 53 tests — sshd_config
│           └── test_key_rotation.sh       # 14 tests — rotation
│
└── docs/
    ├── installation.md                    # Installation guide
    ├── usage.md                           # Full usage manual
    ├── security.md                        # Threat model & hardening
    ├── code-review-report.md              # Code review findings & fixes
    └── examples/
        ├── connect_falcon1024.sh
        ├── ssh_config_snippet.txt
        └── automated_key_rotation.sh
```

---

## Test Suite

**334+ tests** across 17 test files. All OTK tests can run without OQS binaries.

```bash
# OTK-PQ tests (no OQS binary required)
bash shared/tests/unit_tests/test_otk_config.sh              # 33 tests
bash shared/tests/unit_tests/test_otk_session_key.sh         # 18 tests
bash shared/tests/unit_tests/test_otk_lifecycle.sh           # 17 tests
bash shared/tests/unit_tests/test_otk_master_key.sh          # 15 tests
bash shared/tests/unit_tests/test_otk_revocation_ledger.sh   # 20 tests

# Base unit tests (no OQS binary required)
bash shared/tests/unit_tests/test_validation.sh              # 44 tests
bash shared/tests/unit_tests/test_logging.sh                 # 26 tests
# ... and more

# Integration tests (auto-skip if OQS absent)
bash shared/tests/integration_tests/test_server.sh           # 53 tests
```

---

## Design Philosophy

**Nothing persists.** Session keys exist only for the duration of a single connection. There is no key to steal because there is no key that lasts.

**Trust is layered.** The master key anchors identity. The hybrid layer ensures quantum resilience. The one-time mechanism ensures temporal isolation. An attacker must defeat all three layers simultaneously.

**Destruction is a feature.** In traditional systems, key destruction is an afterthought. In OTK-PQ, it is the core mechanism. The system is designed around the assumption that every key will be destroyed — the question is only whether the session completes first.

---

## Contributing

1. Fork the repository and create a branch from `master`
2. Follow the existing conventions (source `shared/config.sh` + `shared/functions.sh`, use `log_*` for output, `validate_*` for input)
3. Add tests in `shared/tests/` for any new logic
4. Ensure all existing tests pass before opening a pull request

---

## License

Proprietary — Trednets B.V.

## Author

Yarpii — CEO, Trednets

---

*Every connection is unique. Every key is temporary. Every session is final.*
