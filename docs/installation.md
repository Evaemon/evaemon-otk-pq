# Installation Guide

This guide walks you through installing Evaemon on both a **server** and a **client** machine. By the end you will have a fully functional post-quantum SSH server and at least one authenticated client.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Obtaining the toolkit](#obtaining-the-toolkit)
3. [Building OQS-OpenSSH](#building-oqs-openssh)
4. [Server setup](#server-setup)
5. [Client setup](#client-setup)
6. [Verifying the installation](#verifying-the-installation)
7. [Uninstalling](#uninstalling)

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

The build process downloads and compiles liboqs and OQS-OpenSSH from source.

| Artifact | Approximate size |
|---|---|
| Source downloads | ~150 MB |
| Build artefacts | ~400 MB |
| Final install (build/) | ~80 MB |

---

## Obtaining the toolkit

Clone the repository to a directory of your choice:

```bash
git clone https://github.com/Yarpii/Evaemon.git
cd Evaemon
```

All scripts are relative to this directory. The working directory throughout this guide is assumed to be the repository root.

---

## Building OQS-OpenSSH

The build script fetches liboqs and OQS-OpenSSH, compiles them, and installs the binaries under `build/`:

```bash
sudo bash build_oqs_openssh.sh
```

This takes 5-20 minutes depending on your CPU. When it finishes, verify the binary is present:

```bash
build/bin/ssh -V
```

Expected output (version numbers may vary):
```
OpenSSH_9.x OQS-v9.x, liboqs x.x.x
```

> **Recommended:** launch the build from the wizard (`wizard.sh`). The wizard runs the build in the background and shows a live step-by-step progress gauge so you can see exactly which phase is running:
> ```
> Step 1/7 — Installing dependencies
> Step 2/7 — Cloning liboqs
> Step 3/7 — Building liboqs
> Step 4/7 — Cloning OpenSSH
> Step 5/7 — Compiling OpenSSH
> Step 6/7 — Linking shared libraries
> Step 7/7 — Finalizing installation
> ```
> If the build fails, the wizard offers to open the full build log in a scrollable viewer without leaving the GUI.

---

## Server setup

Run the interactive wizard as root:

```bash
sudo bash wizard.sh
```

Select **1 (Server)** at the mode selection prompt, then follow the menu:

### Step 1 - Build OQS-OpenSSH (if not done already)

Menu option **1 - Build and install OQS-OpenSSH**

### Step 2 - Configure the server

Menu option **2 - Configure Server**

You will be prompted to select an **algorithm mode**:

| Mode | Description |
|------|-------------|
| `1`  | All PQ algorithms — host keys and `HostKeyAlgorithms` cover all 10 PQ types |
| `2`  | Select specific PQ algorithms — choose a subset by security level or performance |
| `3`  | Hybrid (all PQ) — adds Ed25519 + RSA host keys; classical clients can connect too |
| `4`  | Hybrid (select PQ) — choose PQ algorithms + Ed25519 + RSA |

Falcon-1024 is recommended for most deployments (NIST Level 5, fast verification). For environments that also need to support standard OpenSSH clients, choose a hybrid mode (3 or 4).

The script will then:
- Generate one host key pair per selected algorithm in `build/etc/keys/`
- Write `build/etc/sshd_config` with `HostKeyAlgorithms`, `PubkeyAcceptedKeyTypes`, and `KexAlgorithms`
- Install and enable the `evaemon-sshd` systemd service

### Starting the service

```bash
sudo systemctl start evaemon-sshd.service
sudo systemctl status evaemon-sshd.service
```

### Firewall

Open the configured SSH port (default 22) if a firewall is active:

```bash
# ufw (Ubuntu)
sudo ufw allow 22/tcp

# firewalld (RHEL)
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --reload
```

---

## Client setup

The client machine must also have OQS-OpenSSH built. Repeat the Build step on the client, or copy the `build/` directory from the server.

### Step 1 - Generate a key pair

```bash
sudo bash wizard.sh
# Select: 2 (Client) -> 2 (Generate Keys)
```

Choose a key type:
- **Post-quantum** — pick from the list of PQ algorithms; must match an algorithm the server advertises
- **Classical** — Ed25519 or RSA; only works if the server was configured in hybrid mode (3 or 4)

> In hybrid mode you can mix PQ and classical client keys across different users. In PQ-only mode (1 or 2) every client key must be a PQ algorithm the server has a host key for.

Keys are written to `~/.ssh/id_<algorithm>` and `~/.ssh/id_<algorithm>.pub`.

### Step 2 - Copy the public key to the server

```bash
# Select: 2 (Client) -> 3 (Copy Key to Server)
```

Enter the server address, username, and port when prompted. The public key is appended to `~/.ssh/authorized_keys` on the server.

Alternatively, copy manually:

```bash
cat ~/.ssh/id_ssh-falcon1024.pub | \
  ssh user@server "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### Step 3 - Connect

```bash
# Select: 2 (Client) -> 4 (Connect to Server)
```

Or directly (PQ-only):

```bash
build/bin/ssh \
  -o "KexAlgorithms=ecdh-nistp384-kyber-1024r3-sha384-d00@openquantumsafe.org,ecdh-nistp256-kyber-512r3-sha256-d00@openquantumsafe.org" \
  -o "HostKeyAlgorithms=ssh-falcon1024" \
  -o "PubkeyAcceptedKeyTypes=ssh-falcon1024" \
  -i ~/.ssh/id_ssh-falcon1024 \
  -p 22 user@server
```

The `KexAlgorithms` flag ensures the session key exchange also uses a post-quantum-resistant algorithm, not just the authentication step. `client/connect.sh` sets this automatically.

---

## Verifying the installation

Use the built-in health check to confirm everything works end-to-end:

```bash
# Select: 2 (Client) -> 6 (Health Check)
```

The health check performs five stages:
- OQS binary presence
- Key file + permissions
- TCP reachability
- SSH handshake (echo probe)
- Server host key fingerprint

All stages should report **PASS**.

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

All tests should exit with code 0 (199 tests total).

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

3. Optionally remove generated keys:
   ```bash
   rm -f ~/.ssh/id_ssh-* ~/.ssh/id_ssh-*.pub
   ```

The system's standard OpenSSH installation is never modified by this toolkit.
