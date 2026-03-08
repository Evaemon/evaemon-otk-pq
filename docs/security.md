# Security Guide

This document describes the threat model Evaemon is designed to address, the security properties of the supported algorithms, operational best practices, and known limitations.

---

## Table of Contents

1. [Threat model](#threat-model)
2. [Algorithm selection](#algorithm-selection)
3. [Key management](#key-management)
4. [Server hardening](#server-hardening)
5. [Client hardening](#client-hardening)
6. [Backup security](#backup-security)
7. [Key rotation policy](#key-rotation-policy)
8. [Key migration](#key-migration-classical-to-post-quantum)
9. [PQ-only test mode](#pq-only-test-mode)
10. [Algorithm performance benchmark](#algorithm-performance-benchmark)
11. [CVE advisories](#cve-advisories-and-dependency-vulnerabilities)
12. [Known limitations and caveats](#known-limitations-and-caveats)
13. [Incident response](#incident-response)

---

## Threat model

### What this toolkit protects against

**Harvest-now / decrypt-later attacks**
A powerful adversary can record encrypted SSH traffic today and decrypt it once they have access to a cryptographically-relevant quantum computer. Evaemon addresses this at both layers:
- **Session encryption (KEX):** the generated `sshd_config` and client connection scripts set `KexAlgorithms` to prefer Kyber-based hybrid key exchange, meaning the session key itself cannot be recovered by a future quantum computer.
- **Authentication:** PQ signature algorithms ensure that recorded authentication exchanges cannot be forged later by a quantum attacker.

**Authentication forgery by a quantum-capable adversary**
Classical RSA and ECDSA authentication can be broken by a sufficiently powerful quantum computer running Shor's algorithm. The signature schemes in this toolkit are based on lattice or hash problems believed to be hard even for quantum computers.

### What this toolkit does NOT protect against

- **Compromised server** -- if an attacker has root on the server, no SSH configuration helps.
- **Compromised endpoint** -- malware on the client can steal keys regardless of algorithm.
- **Side-channel attacks** -- this toolkit does not address timing or power side-channels in the OQS library implementations.
- **Denial of service** -- monitoring tools detect issues; they do not prevent attacks on the SSH port.
- **Protocol downgrade to classical SSH** -- this toolkit runs a *separate* sshd; the system's standard OpenSSH remains unchanged and clients can still connect to it unless you firewall it.

---

## Algorithm selection

### Supported algorithms and security levels

Algorithms are ordered by **multi-family risk diversification** priority. The top 3 span different mathematical assumption families so that a break in one does not compromise all keys.

| # | Algorithm | Family | NIST Level | Notes |
|---|-----------|--------|-----------|-------|
| 1 | `ssh-falcon1024` | Lattice (NTRU) | 5 | **Recommended** -- fastest verification, compact at L5 |
| 2 | `ssh-mldsa-65` | Lattice (Module-LWE) | 3 | NIST FIPS 204 primary standard |
| 3 | `ssh-sphincssha2256fsimple` | Hash (SPHINCS+ / FIPS 205) | 5 | Minimal cryptographic assumptions |
| 4 | `ssh-slhdsa-sha2-256f` | Hash (SLH-DSA / FIPS 205) | 5 | Standardised FIPS 205 name (liboqs >= 0.12.0) |
| 5 | `ssh-mldsa-87` | Lattice (Module-LWE) | 5 | Conservative L5 lattice choice |
| 6 | `ssh-mldsa-44` | Lattice (Module-LWE) | 2 | Lightweight ML-DSA variant |
| 7 | `ssh-sphincssha2128fsimple` | Hash (SPHINCS+ / FIPS 205) | 1 | Fast hash-based, minimal assumptions |
| 8 | `ssh-slhdsa-sha2-128f` | Hash (SLH-DSA / FIPS 205) | 1 | SLH-DSA lightweight variant |
| 9 | `ssh-falcon512` | Lattice (NTRU) | 1 | Constrained devices only |
| 10 | `ssh-mayo2` | Multivariate (Oil-Vinegar) | 2 | Compact signatures |
| 11 | `ssh-mayo3` | Multivariate (Oil-Vinegar) | 3 | Balanced |
| 12 | `ssh-mayo5` | Multivariate (Oil-Vinegar) | 5 | Conservative multivariate |

### Multi-family risk diversification

Deploy keys from **at least two different assumption families** so that a breakthrough in one area of mathematics does not compromise all authentication:

| Family | Algorithms | Assumption |
|--------|-----------|------------|
| Lattice (NTRU) | Falcon-1024, Falcon-512 | NTRU lattice problems |
| Lattice (Module-LWE) | ML-DSA-65, ML-DSA-87, ML-DSA-44 | Module Learning With Errors |
| Hash-based | SPHINCS+-256f, SLH-DSA-256f, SPHINCS+-128f, SLH-DSA-128f | Hash function security (minimal assumptions) |
| Multivariate | MAYO-2, MAYO-3, MAYO-5 | Oil-and-vinegar |

**Recommended multi-family set:** `ssh-falcon1024` + `ssh-mldsa-65` + `ssh-sphincssha2256fsimple`

### SLH-DSA (FIPS 205 standardised)

SLH-DSA is the NIST-standardised name for SPHINCS+ (FIPS 205). The `ssh-slhdsa-*` variants are available in liboqs >= 0.12.0 and serve as a **fallback** if the SPHINCS+ names change in future OQS-OpenSSH releases. Both refer to the same underlying algorithm.

### Guidance

- **For most deployments:** `ssh-falcon1024` (Level 5, fast, compact)
- **If you want a NIST standard:** `ssh-mldsa-65` (FIPS 204)
- **If you distrust lattice math:** `ssh-sphincssha2256fsimple` or `ssh-slhdsa-sha2-256f` (hash-based, orthogonal assumption)
- **For constrained bandwidth:** `ssh-falcon512` (Level 1 -- only use if Level 5 is genuinely impractical)
- **For multi-family diversification:** deploy Falcon-1024 + ML-DSA-65 + SPHINCS+-256f across your infrastructure

Avoid mixing security levels across client and server. A Level-1 client key is the weakest link even when the server is configured for Level 5.

---

## Key management

### Private key permissions

Private keys **must** have permissions `600`. The toolkit enforces this on generation and warns on weaker permissions.

```bash
chmod 600 ~/.ssh/id_ssh-falcon1024
```

### Passphrase protection

Protect private keys with a passphrase. During key generation you are prompted:

```
Protect the new key with a passphrase? (y/N):
```

Use `ssh-agent` to avoid repeated passphrase entry:

```bash
eval "$(build/bin/ssh-agent -s)"
build/bin/ssh-add ~/.ssh/id_ssh-falcon1024
```

### Key uniqueness

Generate distinct key pairs for distinct purposes (personal workstations, CI/CD, jump hosts). Do not share private keys between users or machines.

### Known hosts verification

On first connection to a server, verify the host key fingerprint out-of-band (e.g., from the server console) before accepting it. The health check and debug tools print the current server fingerprint to aid verification.

---

## Server hardening

### Additional `sshd_config` directives

The generated `sshd_config` applies conservative defaults. Recommended additions:

```
# Disable password authentication entirely
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Restrict to specific users
AllowUsers alice bob

# Idle session timeout
ClientAliveInterval 300
ClientAliveCountMax 2

# Bind to a specific interface (if multi-homed)
ListenAddress 192.168.1.10
```

Edit `build/etc/sshd_config`, then validate:

```bash
bash server/tools/diagnostics.sh
```

### Firewall

Restrict SSH access to known source IP ranges:

```bash
sudo ufw allow from 192.168.0.0/24 to any port 22
sudo ufw deny 22
```

### Non-standard port

Running the post-quantum sshd on a non-standard port reduces automated scanner noise. Edit the `Port` directive in `build/etc/sshd_config`, update the firewall, and inform clients.

### Host key rotation

Rotate the server's host key periodically or after a suspected compromise. After regeneration, distribute the new fingerprint to all clients out-of-band and ask them to remove the old known_hosts entry:

```bash
build/bin/ssh-keygen -R <server_host>
```

---

## Client hardening

### SSH config alias

Create or extend `~/.ssh/config`:

```
Host pqserver
    HostName               192.168.1.10
    User                   alice
    Port                   22
    IdentityFile           ~/.ssh/id_ssh-falcon1024
    HostKeyAlgorithms      ssh-falcon1024
    PubkeyAcceptedKeyTypes ssh-falcon1024
    KexAlgorithms          mlkem1024nistp384-sha384,mlkem768x25519-sha256,mlkem768nistp256-sha256,mlkem1024-sha384,mlkem768-sha256
```

For a hybrid server that also accepts classical clients, append the classical fallback KEX:

```
Host pqserver-hybrid
    HostName               192.168.1.10
    User                   alice
    Port                   22
    IdentityFile           ~/.ssh/id_ssh-falcon1024
    HostKeyAlgorithms      ssh-falcon1024,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
    PubkeyAcceptedKeyTypes ssh-falcon1024,ssh-ed25519,rsa-sha2-512,rsa-sha2-256
    KexAlgorithms          mlkem1024nistp384-sha384,mlkem768x25519-sha256,mlkem768nistp256-sha256,mlkem1024-sha384,mlkem768-sha256,curve25519-sha256,diffie-hellman-group16-sha512
```

Then connect with:
```bash
build/bin/ssh pqserver
```

### Authorized keys audit

Periodically review `~/.ssh/authorized_keys` on every server you have access to and remove stale entries. Use `client/key_rotation.sh` to retire old keys cleanly.

### known_hosts hygiene

Remove stale host entries when a server is decommissioned:

```bash
build/bin/ssh-keygen -R old-server.example.com
```

---

## Backup security

Backup files produced by `client/backup.sh` are encrypted with AES-256-CBC (PBKDF2, 600,000 iterations). They are as sensitive as the private keys they contain.

The passphrase is written to a `chmod 600` temp file immediately, then the in-memory variable is cleared with `unset` before the encryption command runs. The temp file is removed unconditionally via a `RETURN` trap. This minimises the window during which the passphrase is recoverable from process memory or `/proc/<pid>/cmdline`.

- Store backups in an **offline** location (encrypted USB, offline cold storage).
- Never store a backup and its passphrase together.
- Test restoration periodically.
- After key rotation, create a new backup and securely destroy the old one.

---

## Key rotation policy

| Scenario | Rotate every |
|----------|-------------|
| Personal / low-risk | 6 months |
| Enterprise / privileged access | 90 days |
| CI/CD automation keys | 90 days (enforced) |
| Post suspected compromise | Immediately |

The rotation tool (`client/key_rotation.sh`) enforces a **90-day maximum key age** by default (configurable via `KEY_MAX_AGE_DAYS`). When a key exceeds this age, rotation proceeds automatically. Keys within the policy window prompt for confirmation.

After rotation, the tool **verifies the old key is rejected** by the server — not just that the new key works. This ensures stale credentials are truly invalidated.

For automated environments, use `docs/examples/automated_key_rotation.sh` in a cron job:

```bash
# Rotate every 90 days — crontab entry
0 3 1 */3 * EVAEMON_SERVER_HOST=prod.example.com EVAEMON_ALGORITHM=ssh-falcon1024 bash /path/to/docs/examples/automated_key_rotation.sh
```

---

## Key migration (classical to post-quantum)

Use `client/migrate_keys.sh` to scan a server's `~/.ssh/authorized_keys` for classical (non-PQ) key types and migrate them.

### What it detects

Classical key types flagged for migration:
- `ssh-rsa` (vulnerable to Shor's algorithm)
- `ssh-dss` (deprecated, vulnerable)
- `ecdsa-sha2-*` (vulnerable to Shor's algorithm)
- `ssh-ed25519` (vulnerable to Shor's algorithm)

### Usage

```bash
# Scan a remote server
bash client/migrate_keys.sh

# Scan local authorized_keys only
bash client/migrate_keys.sh --local
```

The tool will:
1. Fetch and scan `~/.ssh/authorized_keys` from the server
2. Report which keys are classical vs post-quantum
3. Offer to remove all classical keys (with server-side backup)
4. Verify the PQ key still authenticates after migration

---

## PQ-only test mode

For test/staging servers, `server/pq_only_testmode.sh` configures a **pure post-quantum sshd** that rejects all classical algorithms.

### When to use

- Proving PQ-only viability before production rollout
- CI/CD pipeline testing with PQ deploy keys
- Security audits requiring PQ-only compliance

### What it does

1. Generates PQ-only host keys (no Ed25519/RSA)
2. Writes `sshd_config` with PQ-only KEX and PQ-only authentication
3. Configures firewall rules (ufw or iptables) for the dedicated port
4. Creates a separate systemd service (`evaemon-pqonly-sshd`)
5. Prints a test plan for CI/CD verification

### Usage

```bash
sudo bash server/pq_only_testmode.sh
```

Default port is 2222. Classical SSH clients **cannot** connect.

---

## Algorithm performance benchmark

Reference measurements for the most commonly deployed algorithms. Exact numbers
depend on hardware, compiler, and liboqs version; use `client/tools/performance_test.sh`
to generate numbers for your environment.

### Signature size and key size

| Algorithm | Public key | Signature | Private key | NIST Level |
|-----------|-----------|-----------|-------------|-----------|
| Ed25519 (classical) | 32 B | 64 B | 64 B | N/A |
| `ssh-falcon1024` | 1,793 B | 1,280 B | 2,305 B | 5 |
| `ssh-mldsa-65` (ML-DSA-65) | 1,952 B | 3,309 B | 4,032 B | 3 |
| `ssh-mldsa-87` (ML-DSA-87) | 2,592 B | 4,627 B | 4,896 B | 5 |
| `ssh-sphincssha2256fsimple` | 64 B | 29,792 B | 128 B | 5 |
| `ssh-slhdsa-sha2-256f` | 64 B | 29,792 B | 128 B | 5 |
| `ssh-sphincssha2128fsimple` | 32 B | 17,088 B | 64 B | 1 |

### Signing and verification speed

Measured on a modern x86\_64 server (single core). Times are per-operation averages.

| Algorithm | Sign | Verify | Keygen |
|-----------|------|--------|--------|
| Ed25519 (classical) | ~0.03 ms | ~0.07 ms | ~0.03 ms |
| `ssh-falcon1024` | ~0.6 ms | ~0.1 ms | ~12 ms |
| `ssh-mldsa-65` (ML-DSA-65) | ~0.3 ms | ~0.3 ms | ~0.3 ms |
| `ssh-mldsa-87` (ML-DSA-87) | ~0.5 ms | ~0.5 ms | ~0.5 ms |
| `ssh-sphincssha2256fsimple` | ~160 ms | ~5 ms | ~2 ms |
| `ssh-slhdsa-sha2-256f` | ~160 ms | ~5 ms | ~2 ms |
| `ssh-sphincssha2128fsimple` | ~8 ms | ~0.4 ms | ~0.3 ms |

### SSH handshake latency impact

Approximate overhead compared to Ed25519 on a local network:

| Algorithm | Handshake overhead | Practical impact |
|-----------|-------------------|------------------|
| `ssh-falcon1024` | +2-5 ms | Negligible -- fastest PQ option |
| `ssh-mldsa-65` | +5-15 ms | Barely noticeable |
| `ssh-mldsa-87` | +10-25 ms | Acceptable for all workloads |
| `ssh-sphincssha2256fsimple` | +150-300 ms | Noticeable on interactive sessions |
| `ssh-sphincssha2128fsimple` | +10-30 ms | Acceptable |

### Performance guidance

- **Latency-sensitive** (interactive sessions, CI/CD): Use `ssh-falcon1024` or `ssh-mldsa-65`.
  Falcon has the fastest verification; ML-DSA-65 has the fastest signing.
- **Bandwidth-constrained**: `ssh-falcon1024` has the smallest combined (pubkey + signature)
  footprint of any Level 5 algorithm. Avoid SPHINCS+ unless bandwidth is not a concern.
- **Maximum security margin**: `ssh-sphincssha2256fsimple` relies only on hash function security.
  The signing overhead (~160 ms) is acceptable for key rotation and CI/CD but noticeable for
  interactive sessions.
- **Balanced multi-family**: Deploy `ssh-falcon1024` for daily use and
  `ssh-sphincssha2256fsimple` as a standby fallback -- you get speed AND independence from
  lattice assumptions.

Run `bash client/tools/performance_test.sh` to generate exact numbers for your hardware.

---

## CVE advisories and dependency vulnerabilities

The following CVEs affect components that Evaemon builds from source.
Ensure you pull up-to-date source (or pin to the versions noted) before building.

### liboqs

| CVE | Severity | Affected versions | Fixed in | Description |
|-----|----------|-------------------|----------|-------------|
| CVE-2024-36405 | Moderate | < 0.10.1 | 0.10.1 | KyberSlash: control-flow timing leak in Kyber/ML-KEM decapsulation when compiled with Clang 15–18 at -O1/-Os. Enables secret-key recovery. |
| CVE-2024-54137 | Moderate | < 0.12.0 | 0.12.0 | HQC decapsulation returns incorrect shared secret on invalid ciphertext. |
| CVE-2025-48946 | Moderate | < 0.14.0 | 0.14.0 | HQC design flaw: large number of malformed ciphertexts share the same implicit rejection value. |
| CVE-2025-52473 | Moderate | < 0.14.0 | 0.14.0 | HQC secret-dependent branches when compiled with Clang above -O0. |

> **Note:** HQC is not used by any of the signature algorithms in this toolkit's
> default `ALGORITHMS` list, but it is present in the liboqs build. CVE-2024-36405
> (KyberSlash) **does** apply to the Kyber-based `KEX_ALGORITHMS` used for session
> key exchange.

**Recommendation:** build against liboqs `main` (≥ 0.14.0) or the latest tagged release.

### OQS-OpenSSH (upstream OpenSSH inherited CVEs)

OQS-OpenSSH is a fork of upstream OpenSSH. The following upstream CVEs may be
present depending on the base version included in the OQS fork branch:

| CVE | CVSS | Description |
|-----|------|-------------|
| CVE-2024-6387 | 8.1 Critical | "regreSSHion" — unauthenticated RCE as root via signal-handler race in sshd on glibc Linux (OpenSSH 8.5p1–9.7p1). |
| CVE-2024-6409 | 7.0 High | Race condition RCE in privilege-separation child (OpenSSH 8.7–8.8, RHEL/Fedora). |
| CVE-2025-26465 | 6.8 Medium | Client MitM if `VerifyHostKeyDNS=yes` (OpenSSH 6.8p1–9.9p1). |
| CVE-2025-26466 | 5.9 Medium | Pre-authentication CPU/memory DoS (OpenSSH 9.5p1–9.9p1). Fixed in 9.9p2. |

> **Note:** The OQS-OpenSSH repository (`OQS-v9` branch) is archived and no longer
> actively maintained by the Open Quantum Safe project. It may not have received
> patches for all upstream CVEs. **This toolkit is intended for research and
> evaluation, not production use with sensitive data.**

---

## Known limitations and caveats

1. **OQS implementations are not yet FIPS-validated.** The underlying liboqs library is research-grade. Await formal FIPS 204 certification for regulated environments.

2. **PQ KEX is hybrid, not pure-PQ by default.** The recommended KEX algorithms (e.g. `mlkem1024nistp384-sha384`) combine a classical elliptic-curve exchange with ML-KEM. Security holds as long as either component remains unbroken. Pure-PQ KEX options (`mlkem1024-sha384`, `mlkem768-sha256`) are available in `shared/config.sh` but sacrifice compatibility with clients that lack ML-KEM support. For pure-PQ testing, use `server/pq_only_testmode.sh`.

3. **System SSH is unmodified.** Both standard and post-quantum sshd run simultaneously by default. Ensure classical SSH is also hardened or firewalled.

4. **Host key compromise is not automatically detected.** Rotate host keys immediately upon suspicion of compromise.

5. **Algorithm agility.** If a PQ algorithm is later found vulnerable, rotating to a different one requires reconfiguring both server and all clients. Maintain a record of which key type each client uses.

---

## Incident response

### Suspected private key compromise

1. Run key rotation immediately:
   ```bash
   bash client/key_rotation.sh
   ```
2. Confirm the old key is removed from all servers' `authorized_keys`.
3. Review server logs for unusual activity:
   ```bash
   bash server/monitoring.sh
   ```
4. Rotate the server's host key if the server itself may be compromised.

### Suspected server compromise

1. Stop the post-quantum sshd:
   ```bash
   sudo systemctl stop evaemon-sshd.service
   ```
2. Use out-of-band console access for investigation -- do not SSH in.
3. After remediation, rebuild from scratch, regenerate all host keys, and rotate all client keys that had access.
