# Evaemon

> **The last infrastructure.**

Evaemon is a complete toolkit for deploying and managing post-quantum SSH connections. It wraps [OQS-OpenSSH](https://github.com/open-quantum-safe/openssh) with an interactive wizard, a full suite of client and server management tools, a test suite, and thorough documentation — so you can replace classical SSH authentication with quantum-resistant algorithms without touching your system's standard OpenSSH installation.

---

## Quick start

```bash
git clone https://github.com/Yarpii/Evaemon.git
cd Evaemon
sudo bash wizard.sh
```

The wizard guides you through building OQS-OpenSSH, configuring the server, and setting up clients.

---

## Features

- **Quantum-resistant authentication** using NIST-selected and candidate algorithms (Falcon, ML-DSA, Dilithium, SPHINCS+)
- **Post-quantum key exchange** — session encryption protected by hybrid Kyber-based KEX algorithms (`KexAlgorithms`), not just authentication
- **Hybrid mode** — server and client simultaneously support classical (Ed25519, RSA) and post-quantum algorithms; interoperates with standard OpenSSH clients while also accepting PQ keys
- **Multi-algorithm server** — generate and advertise multiple host key types at once; clients negotiate the algorithm they support
- **Reliable operations** — exponential-backoff retry logic on TCP checks, SSH handshakes, and key rotation verification
- **Non-invasive** — runs a separate sshd process; your system OpenSSH is never modified
- **Branded interactive wizard** — dark cyan-on-black terminal GUI (whiptail); EVAEMON ASCII logo splash on launch; OQS build status shown at a glance in the main menu; dynamic `[INSTALLED]` / `[NOT BUILT - START HERE]` labels on every Build menu item; the build runs in the background and streams a step-aware progress gauge (`Step 1/7 — Installing dependencies` … `Step 7/7 — Finalizing installation`); failed builds offer an inline scrollable log viewer; every tool also works standalone without the wizard
- **Client tools** — key generation (PQ and classical), server copy, connection, backup/restore, health check, key rotation, debug, performance benchmark
- **Server tools** — setup, monitoring, update/rebuild, diagnostics
- **Shared library** — centralised logging (with millisecond timestamps and `log_success`), validation, retry helpers, and configuration used by every script
- **Test suite** — 199 tests across 8 files; self-contained bash harness with unit tests and integration tests; auto-skips tests that require the OQS binary when it is not yet built

---

## Supported algorithms

### Authentication (host keys and client keys)

| Algorithm | NIST Level | Type | Notes |
|-----------|-----------|------|-------|
| `ssh-falcon1024` | 5 | Lattice (NTRU) | Recommended — fastest, compact signatures |
| `ssh-mldsa66` | 3 | Lattice (Module-LWE) | NIST standard (FIPS 204) |
| `ssh-mldsa44` | 2 | Lattice (Module-LWE) | Lighter ML-DSA variant |
| `ssh-dilithium5` | 5 | Lattice (Module-LWE) | Conservative L5 choice |
| `ssh-dilithium3` | 3 | Lattice (Module-LWE) | Balanced |
| `ssh-dilithium2` | 2 | Lattice (Module-LWE) | Lightweight |
| `ssh-falcon512` | 1 | Lattice (NTRU) | Constrained devices only |
| `ssh-sphincssha256192frobust` | 3 | Hash (SPHINCS+) | Conservative, hash-based |
| `ssh-sphincssha256128frobust` | 1 | Hash (SPHINCS+) | Fast verification |
| `ssh-sphincsharaka192frobust` | 3-4 | Hash (SPHINCS+) | Minimal assumptions |

In **hybrid mode** the server also accepts `ed25519` and `rsa` host/client keys alongside the PQ algorithms above.

### Key exchange (session encryption)

| Algorithm | Base | Notes |
|-----------|------|-------|
| `ecdh-nistp384-kyber-1024r3-sha384-d00@openquantumsafe.org` | P-384 + Kyber1024 | Highest security, hybrid |
| `ecdh-nistp256-kyber-512r3-sha256-d00@openquantumsafe.org` | P-256 + Kyber512 | Balanced, hybrid |
| `x25519-kyber-512r3-sha256-d00@openquantumsafe.org` | X25519 + Kyber512 | Fast, hybrid |
| `kyber-1024r3-sha512-d00@openquantumsafe.org` | Kyber1024 | Pure PQ |
| `kyber-512r3-sha256-d00@openquantumsafe.org` | Kyber512 | Pure PQ, lightweight |

PQ KEX algorithms are always preferred over classical ones. In hybrid deployments, classical KEX (`curve25519-sha256`, etc.) is appended as a fallback so that standard SSH clients can still connect.

---

## Project structure

```
Evaemon/
├── wizard.sh                       # Interactive entry point (run this first)
├── build_oqs_openssh.sh            # Builds liboqs + OQS-OpenSSH from source
│
├── client/
│   ├── keygen.sh                   # Generate a PQ or classical key pair
│   ├── copy_key_to_server.sh       # Push public key to server authorized_keys
│   ├── connect.sh                  # PQ-only or hybrid SSH session
│   ├── backup.sh                   # AES-256 encrypted key backup / restore
│   ├── health_check.sh             # Five-stage connectivity and auth check (with retry)
│   ├── key_rotation.sh             # Safe key rotation with verified cutover (with retry)
│   └── tools/
│       ├── debug.sh                # Verbose diagnostics and -vvv session log
│       └── performance_test.sh     # Keygen time, key sizes, handshake latency
│
├── server/
│   ├── server.sh                   # Server setup: host keys, sshd_config, systemd (4 modes)
│   ├── monitoring.sh               # Service status, connections, auth events
│   ├── update.sh                   # Rebuild OQS-OpenSSH and restart sshd safely
│   └── tools/
│       └── diagnostics.sh          # Config dump, syntax check, port conflicts, log tail
│
├── shared/
│   ├── config.sh                   # Central configuration (paths, PQ/classical algorithms, KEX)
│   ├── logging.sh                  # Structured logging: levels, ms timestamps, log_success
│   ├── validation.sh               # Input validation (IP, port, username, paths)
│   ├── functions.sh                # Shared helpers: list_algorithms, retry_with_backoff
│   └── tests/
│       ├── test_runner.sh          # Self-contained bash test harness
│       ├── unit_tests/
│       │   ├── test_validation.sh  # 44 tests — validation.sh
│       │   ├── test_logging.sh     # 26 tests — logging.sh (incl. log_success)
│       │   ├── test_functions.sh   # 13 tests — retry_with_backoff + log_success
│       │   ├── test_backup.sh      # 13 tests — do_backup / do_restore roundtrip
│       │   ├── test_copy_key.sh    # 10 tests — copy_client_key (mock SSH binary)
│       │   └── test_connect.sh     # 15 tests — connect() KexAlgorithms args (mock SSH)
│       └── integration_tests/
│           ├── test_keygen.sh      # 11 tests — key generation (skips if OQS absent)
│           ├── test_server.sh      # 53 tests — sshd_config multi-algo, hybrid, KexAlgorithms
│           └── test_key_rotation.sh # 14 tests — archive_old_key + verify_new_key retry
│
└── docs/
    ├── installation.md             # Step-by-step installation guide
    ├── usage.md                    # Full usage manual with CLI examples
    ├── security.md                 # Threat model, hardening, rotation policy
    └── examples/
        ├── connect_falcon1024.sh          # Direct connection script (no wizard)
        ├── ssh_config_snippet.txt         # Ready-to-paste ~/.ssh/config blocks
        └── automated_key_rotation.sh      # Non-interactive rotation for cron/CI
```

---

## Installation

See **[docs/installation.md](docs/installation.md)** for the full guide. The short version:

```bash
# 1. Install build dependencies (Debian/Ubuntu)
sudo apt-get install -y git cmake ninja-build gcc make libssl-dev zlib1g-dev autoconf automake libtool pkg-config

# 2. Build OQS-OpenSSH
sudo bash build_oqs_openssh.sh

# 3. Run the wizard
sudo bash wizard.sh
```

---

## Usage

See **[docs/usage.md](docs/usage.md)** for the complete manual. Common operations:

```bash
# Generate a key (PQ or classical)
bash client/keygen.sh

# Connect (PQ-only or hybrid mode)
bash client/connect.sh

# Health check against a server
bash client/health_check.sh

# Rotate a key safely
bash client/key_rotation.sh

# Monitor the server
sudo bash server/monitoring.sh
```

### Running the test suite

```bash
# Unit tests (no OQS binary required)
bash shared/tests/unit_tests/test_validation.sh
bash shared/tests/unit_tests/test_logging.sh
bash shared/tests/unit_tests/test_functions.sh
bash shared/tests/unit_tests/test_backup.sh
bash shared/tests/unit_tests/test_copy_key.sh
bash shared/tests/unit_tests/test_connect.sh

# Integration tests (auto-skip OQS-dependent tests if binary absent)
bash shared/tests/integration_tests/test_keygen.sh
bash shared/tests/integration_tests/test_server.sh
bash shared/tests/integration_tests/test_key_rotation.sh
```

All tests exit 0 on success. The full suite currently counts **199 tests, 0 failures**.

---

## Security

See **[docs/security.md](docs/security.md)** for the full security guide, including:

- Threat model (harvest-now/decrypt-later, authentication forgery)
- Algorithm selection guidance
- Key management and passphrase best practices
- Server and client hardening recommendations
- Key rotation policy
- Incident response procedures

**Important caveats:**
- OQS implementations are not yet FIPS-validated
- The system's standard OpenSSH is not modified — harden or firewall it separately

---

## Contributing

1. Fork the repository and create a branch from `master`
2. Follow the existing script conventions (source `shared/config.sh` + `shared/functions.sh`, use `log_*` for output, `validate_*` for input)
3. Add tests in `shared/tests/` for any new logic
4. Ensure all existing tests pass before opening a pull request

---

## License

See [LICENSE](LICENSE) for terms.

---

*Evaemon — The last infrastructure.*
