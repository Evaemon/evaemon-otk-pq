# Installation Guide — Evaemon OTK-PQ

This guide walks you through installing Evaemon OTK-PQ on both a **server** and a **client** machine. By the end you will have a fully functional post-quantum SSH server with one-time key authentication.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Obtaining the toolkit](#obtaining-the-toolkit)
3. [Building OQS-OpenSSH](#building-oqs-openssh)
4. [Server setup](#server-setup)
5. [Client setup](#client-setup)
6. [OTK-PQ setup](#otk-pq-setup)
7. [Verifying the installation](#verifying-the-installation)
8. [Uninstalling](#uninstalling)

---

## Prerequisites

### Operating system

- Linux (Debian/Ubuntu 20.04+, RHEL/AlmaLinux 8+, or any modern distribution)
- Must be run as **root** (or via `sudo`) for server-side operations

### Required packages

Install the build dependencies before running the build script:

```bash
# Debian / Ubuntu
sudo apt-get update
sudo apt-get install -y \
    git cmake ninja-build gcc make \
    libssl-dev zlib1g-dev \
    autoconf automake libtool pkg-config

# RHEL / AlmaLinux / Fedora
sudo dnf install -y \
    git cmake ninja-build gcc make \
    openssl-devel zlib-devel \
    autoconf automake libtool pkg-config
```

### Disk space

| Artifact | Approximate size |
|---|---|
| Source downloads | ~150 MB |
| Build artefacts | ~400 MB |
| Final install (build/) | ~80 MB |

---

## Obtaining the toolkit

```bash
git clone https://github.com/Yarpii/evaemon-otk-pq.git
cd evaemon-otk-pq
```

All scripts are relative to this directory.

---

## Building OQS-OpenSSH

The build script fetches liboqs and OQS-OpenSSH, compiles them, and installs the binaries under `build/`:

```bash
sudo bash build_oqs_openssh.sh
```

This takes 5-20 minutes depending on your CPU. When it finishes, verify:

```bash
build/bin/ssh -V
```

> **Recommended:** launch the build from the wizard (`sudo bash wizard.sh`). The wizard shows a live step-by-step progress gauge and offers inline log viewing if the build fails.

---

## Server setup

### Standard PQ SSH server

```bash
sudo bash wizard.sh
# Select: 1 (Server) → 2 (Configure sshd)
```

Choose an algorithm mode:

| Mode | Description |
|------|-------------|
| `1` | All PQ algorithms — broadest PQ client compatibility |
| `2` | Select specific PQ algorithms |
| `3` | Hybrid — all PQ + Ed25519 and RSA |
| `4` | Hybrid — select specific PQ + Ed25519 and RSA |

### OTK-PQ server

```bash
sudo bash wizard.sh
# Select: 1 (Server) → 7 (OTK-PQ Setup & Management) → 1 (Setup OTK-PQ Server)
```

Or directly:

```bash
sudo bash server/otk/otk_server.sh setup
```

This initialises:
- The enrollment directory for client master public keys
- The revocation ledger for tracking used session keys

### Starting the service

```bash
sudo systemctl start evaemon-sshd.service
sudo systemctl status evaemon-sshd.service
```

### Firewall

Open the configured SSH port:

```bash
# ufw (Ubuntu)
sudo ufw allow 22/tcp

# firewalld (RHEL)
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --reload
```

---

## Client setup

The client machine must also have OQS-OpenSSH built. Repeat the build step on the client, or copy the `build/` directory from the server.

### Standard PQ key pair

```bash
sudo bash wizard.sh
# Select: 2 (Client) → 2 (Generate Keys)
```

Keys are written to `~/.ssh/id_<algorithm>` and `~/.ssh/id_<algorithm>.pub`.

### Copy public key to server

```bash
# Select: 2 (Client) → 3 (Copy Key to Server)
```

This is required for the bootstrap connection that OTK-PQ uses to push session bundles.

---

## OTK-PQ setup

OTK-PQ setup involves three steps: generate a master key, enroll it on the server, then connect.

### Step 1 — Generate the master key (client)

```bash
sudo bash wizard.sh
# Select: 2 (Client) → 9 (OTK-PQ) → 1 (Generate Master Key)
```

Or directly:

```bash
sudo bash client/otk/master_key.sh generate
```

This creates an ML-DSA-87 (FIPS 204, Level 5) master key pair:
- Private key: `~/.ssh/otk/master/otk_master_sign` (permissions 600, **never leaves the client**)
- Public key: `~/.ssh/otk/master/otk_master_sign.pub` (for server enrollment)

### Step 2 — Enroll the master key (server)

Export the master public key from the client:

```bash
bash client/otk/master_key.sh export > my_master.pub
```

Transfer it to the server (via SCP, USB, or any trusted channel), then enroll:

```bash
sudo bash server/otk/otk_server.sh enroll alice my_master.pub
```

Or through the wizard:

```bash
# Server wizard: 1 (Server) → 7 (OTK-PQ) → 2 (Enroll Client Master Key)
```

> **Important:** Initial enrollment must occur over a trusted channel. If the first key exchange is compromised, the master key is compromised.

> **Validation:** The server validates that the enrolled file is a valid SSH public key (via `ssh-keygen -l -f`) and warns if the key type doesn't match the expected `OTK_MASTER_SIGN_ALGO`. Invalid keys are rejected and not stored.

### Step 3 — Connect with OTK-PQ

```bash
sudo bash wizard.sh
# Select: 2 (Client) → 9 (OTK-PQ) → 5 (OTK Connect)
```

Or directly:

```bash
bash client/otk/otk_connect.sh server_host username [port]
```

Every connection:
1. Generates a fresh ephemeral hybrid key pair
2. Signs it with your master key
3. Pushes the session bundle to the server
4. Connects via the one-time key
5. Destroys all key material after disconnect
6. Adds the session key hash to the revocation ledger

---

## Verifying the installation

### Health check

```bash
bash client/health_check.sh
```

Five stages: binary check → key check → TCP reachability → SSH handshake → host fingerprint.

### OTK-PQ verification

```bash
# Verify master key integrity (also detects incomplete/truncated keys)
bash client/otk/master_key.sh verify

# Check master key info
bash client/otk/master_key.sh info

# View enrolled clients (server)
bash server/otk/otk_server.sh list

# View revocation ledger statistics (server)
bash server/otk/revocation_ledger.sh stats
```

> **Note:** The `verify` command detects incomplete or corrupted master keys that may result from interrupted key generation (e.g. `ssh-keygen` killed mid-operation). It checks for orphaned key halves and truncated private keys.

### Running the test suite

```bash
# OTK-PQ tests (103 assertions, no OQS binary required)
bash shared/tests/unit_tests/test_otk_config.sh
bash shared/tests/unit_tests/test_otk_session_key.sh
bash shared/tests/unit_tests/test_otk_lifecycle.sh
bash shared/tests/unit_tests/test_otk_master_key.sh
bash shared/tests/unit_tests/test_otk_revocation_ledger.sh

# Base unit tests (no OQS binary required)
bash shared/tests/unit_tests/test_validation.sh
bash shared/tests/unit_tests/test_logging.sh
bash shared/tests/unit_tests/test_functions.sh

# Integration tests (auto-skip if OQS absent)
bash shared/tests/integration_tests/test_keygen.sh
bash shared/tests/integration_tests/test_server.sh
bash shared/tests/integration_tests/test_key_rotation.sh
```

All tests exit 0 on success. The full suite counts **334+ tests**.

---

## Uninstalling

1. Stop and disable the service:
   ```bash
   sudo systemctl stop evaemon-sshd.service
   sudo systemctl disable evaemon-sshd.service
   sudo rm /etc/systemd/system/evaemon-sshd.service
   sudo systemctl daemon-reload
   ```

2. Remove build artefacts:
   ```bash
   rm -rf build/
   ```

3. Remove OTK-PQ key material:
   ```bash
   rm -rf ~/.ssh/otk/
   ```

4. Remove standard PQ keys (optional):
   ```bash
   rm -f ~/.ssh/id_ssh-* ~/.ssh/id_ssh-*.pub
   ```

5. Remove server OTK data (optional):
   ```bash
   rm -rf build/etc/otk/
   ```

The system's standard OpenSSH installation is never modified by this toolkit.
