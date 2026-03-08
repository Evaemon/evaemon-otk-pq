# Security Guide — Evaemon OTK-PQ

This document describes the threat model, security properties, operational best practices, and known limitations of Evaemon OTK-PQ.

---

## Table of Contents

1. [OTK-PQ threat model](#otk-pq-threat-model)
2. [Three-layer security architecture](#three-layer-security-architecture)
3. [Algorithm selection](#algorithm-selection)
4. [Key management](#key-management)
5. [OTK-PQ operational security](#otk-pq-operational-security)
6. [Server hardening](#server-hardening)
7. [Client hardening](#client-hardening)
8. [Backup security](#backup-security)
9. [Key rotation policy](#key-rotation-policy)
10. [Algorithm performance](#algorithm-performance)
11. [CVE advisories](#cve-advisories)
12. [Known limitations](#known-limitations)
13. [Incident response](#incident-response)

---

## OTK-PQ threat model

### What OTK-PQ defends against

**Quantum harvest attacks ("capture now, decrypt later")**
Session keys are hybrid (classical + post-quantum) and ephemeral. The master key is post-quantum (ML-DSA-87) and never transmitted. An adversary recording traffic today cannot decrypt it with a future quantum computer.

**Key theft**
Stealing an ephemeral session key after use gains nothing — it is already destroyed on both client and server, and recorded in the revocation ledger. The master private key never touches the network.

**Man-in-the-middle**
Session keys are signed by the master key. An attacker cannot forge the ML-DSA-87 signature without the master private key.

**Replay attacks**
The revocation ledger records every used session key hash. Nonce validation (timestamp + CSPRNG) ensures temporal uniqueness. A replayed session bundle is rejected immediately.

**Server compromise**
The server only holds master *public* keys. The private master key never leaves the client. A compromised server cannot forge session keys or recover the master private key.

### What OTK-PQ does NOT defend against

- **Initial enrollment compromise** — if the first master key transfer is intercepted, the attacker has the master public key (but still needs the private key to forge sessions). If they substitute their own public key during enrollment, they can impersonate the client. Mitigate with out-of-band verification.
- **Client device compromise** — if the client device is fully compromised and the master private key is extracted, the system is broken. Hardware-backed key storage mitigates this.
- **Side-channel attacks** — this toolkit does not address timing or power side-channels in OQS library implementations.
- **Denial of service** — monitoring tools detect issues but do not prevent attacks on the SSH port.
- **Protocol downgrade** — the system's standard OpenSSH remains unchanged; clients can still connect to it unless firewalled.

---

## Three-layer security architecture

### Layer 1 — Post-Quantum Master Key

| Property | Value |
|----------|-------|
| Algorithm | ML-DSA-87 (NIST FIPS 204) |
| Security level | NIST Level 5 |
| Location | Client only — `~/.ssh/otk/master/` |
| Network exposure | **None** — never transmitted after initial enrollment |
| Purpose | Sign ephemeral session keys |
| Rotation | Recommended annually (`OTK_MASTER_MAX_AGE_DAYS=365`) |
| Compromise impact | Full — attacker can forge session keys |

### Layer 2 — Hybrid Session Keys

| Property | Value |
|----------|-------|
| Classical component | Ed25519 (RFC 8032) |
| PQ component | ML-DSA-87 (FIPS 204) |
| KEX | ML-KEM-1024 hybrid (FIPS 203) + X25519 |
| Lifetime | Single session — generated and destroyed per connection |
| Network exposure | Public keys + signature + nonce only |
| Verification | Master key signature verified by server |
| Compromise impact | **Zero** — key is already destroyed and revoked |

### Layer 3 — One-Time Execution & Destruction

| Property | Value |
|----------|-------|
| Destruction method | `shred` (multi-pass overwrite + zero + unlink) |
| Verification | Post-destruction check confirms no residual material |
| Revocation | SHA3-256 hash of session key stored in ledger |
| Replay prevention | Ledger check + nonce timestamp validation |
| Nonce window | 300 seconds (`OTK_NONCE_MAX_AGE`) |
| Ledger pruning | Entries older than 7 days auto-pruned |

### Security properties comparison

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

## Algorithm selection

### OTK-PQ algorithms

| Purpose | Algorithm | Standard | Level |
|---------|-----------|----------|-------|
| Master signing | ML-DSA-87 | FIPS 204 | 5 |
| Master encapsulation | ML-KEM-1024 | FIPS 203 | 5 |
| Session signing | Ed25519 | RFC 8032 | — |
| Session KEX | X25519 + ML-KEM-1024 | RFC 7748 + FIPS 203 | 5 |
| Session KDF | HKDF-SHA-512 | RFC 5869 | — |
| Revocation hash | SHA3-256 | FIPS 202 | — |

### PQ authentication algorithms (host keys and client keys)

| # | Algorithm | Family | NIST Level |
|---|-----------|--------|-----------|
| 1 | `ssh-falcon1024` | Lattice (NTRU) | 5 |
| 2 | `ssh-mldsa-65` | Lattice (Module-LWE) | 3 |
| 3 | `ssh-sphincssha2256fsimple` | Hash (SPHINCS+) | 5 |
| 4 | `ssh-slhdsa-sha2-256f` | Hash (SLH-DSA) | 5 |
| 5 | `ssh-mldsa-87` | Lattice (Module-LWE) | 5 |
| 6 | `ssh-mldsa-44` | Lattice (Module-LWE) | 2 |
| 7 | `ssh-sphincssha2128fsimple` | Hash (SPHINCS+) | 1 |
| 8 | `ssh-slhdsa-sha2-128f` | Hash (SLH-DSA) | 1 |
| 9 | `ssh-falcon512` | Lattice (NTRU) | 1 |
| 10 | `ssh-mayo2` | Multivariate | 2 |
| 11 | `ssh-mayo3` | Multivariate | 3 |
| 12 | `ssh-mayo5` | Multivariate | 5 |

### Multi-family risk diversification

Deploy keys from **at least two different assumption families**:

| Family | Algorithms | Assumption |
|--------|-----------|------------|
| Lattice (NTRU) | Falcon-1024, Falcon-512 | NTRU lattice problems |
| Lattice (Module-LWE) | ML-DSA-87, ML-DSA-65, ML-DSA-44 | Module Learning With Errors |
| Hash-based | SPHINCS+, SLH-DSA | Hash function security |
| Multivariate | MAYO-2, MAYO-3, MAYO-5 | Oil-and-vinegar |

---

## Key management

### Master key (OTK-PQ)

- **Never share the master private key.** It is the root of trust.
- **Protect with a passphrase.** The generation wizard prompts for this.
- **Verify enrollment out-of-band.** Compare fingerprints between client and server.
- **Rotate annually** or immediately upon suspected compromise.
- **Archive old master keys** — the rotation tool archives automatically.

### Standard PQ keys (bootstrap)

- Private keys must have permissions `600`
- Protect with a passphrase
- Generate distinct key pairs per purpose
- Verify host key fingerprints on first connection

### Permissions

| File | Required |
|------|----------|
| Master private key | `600` |
| Master public key | `644` |
| OTK directories | `700` |
| Session keys | `600` (auto-enforced, auto-destroyed) |
| Revocation ledger | `600` |

---

## OTK-PQ operational security

### Nonce validation

Every session bundle includes a nonce (timestamp + 32 bytes CSPRNG). The server rejects bundles with:
- Timestamps in the future (clock skew)
- Timestamps older than `OTK_NONCE_MAX_AGE` (default 300 seconds)
- Non-numeric or malformed timestamps

**Clock synchronisation:** ensure client and server clocks are synchronised within `OTK_NONCE_MAX_AGE` seconds. Use NTP.

### Revocation ledger

- **Location:** `build/etc/otk/ledger/revocation.ledger`
- **Growth:** one entry per session (~80 bytes). At 100 sessions/day, ~2.8 KB/day, ~1 MB/year.
- **Pruning:** entries older than `OTK_LEDGER_PRUNE_DAYS` (default 7) are safe to remove since nonce validation would reject them anyway.
- **Concurrency:** `flock` exclusive lock prevents corruption from simultaneous sessions.
- **Maximum size:** `OTK_LEDGER_MAX_ENTRIES` (default 100,000) triggers a pruning warning.

### Secure destruction

Session key material is destroyed using:
1. **shred** — multi-pass random overwrite + zero pass + unlink (preferred)
2. **Manual overwrite** — `dd` from `/dev/urandom` (fallback if shred unavailable)
3. **Verification** — post-destruction check confirms no files remain

Configure the number of overwrite passes with `OTK_SHRED_PASSES` (default 3).

### Bootstrap connection security

OTK-PQ uses an existing PQ or classical key to push the session bundle to the server. This "bootstrap" connection:
- Must use PQ KEX algorithms (configured automatically)
- Should use a key that is already enrolled via standard `authorized_keys`
- Is separate from the ephemeral session — the session key is what authenticates the actual connection

---

## Server hardening

### sshd_config recommendations

```
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
AllowUsers alice bob
ClientAliveInterval 300
ClientAliveCountMax 2
PermitRootLogin no
```

### Firewall

```bash
sudo ufw allow from 192.168.0.0/24 to any port 22
sudo ufw deny 22
```

### OTK enrollment security

- Verify master key fingerprints out-of-band before enrolling
- Review enrolled clients periodically: `bash server/otk/otk_server.sh list`
- Revoke compromised clients immediately: `bash server/otk/otk_server.sh revoke <name>`
- Prune the revocation ledger periodically: `bash server/otk/revocation_ledger.sh prune`

---

## Client hardening

### SSH config alias

```
Host pqserver-otk
    HostName               192.168.1.10
    User                   alice
    Port                   22
    IdentityFile           ~/.ssh/id_ssh-falcon1024
    HostKeyAlgorithms      ssh-falcon1024,ssh-mldsa-87
    PubkeyAcceptedKeyTypes ssh-falcon1024,ssh-mldsa-87
    KexAlgorithms          mlkem1024nistp384-sha384,mlkem768x25519-sha256,curve25519-sha256
```

### Master key protection

- Use passphrase protection on the master key
- Store on encrypted filesystem where possible
- Consider hardware-backed key storage (TPM / Secure Enclave) for high-security deployments

---

## Backup security

Backup files from `client/backup.sh` are encrypted with AES-256-CBC (PBKDF2, 600,000 iterations).

- Store backups offline (encrypted USB, cold storage)
- Never store a backup and its passphrase together
- After master key rotation, create a new backup and destroy the old one
- OTK session keys are ephemeral and should NOT be backed up (they are destroyed by design)

---

## Key rotation policy

### Master key rotation

| Scenario | Rotate |
|----------|--------|
| Standard | Annually (`OTK_MASTER_MAX_AGE_DAYS=365`) |
| Post suspected compromise | Immediately |
| Regulatory requirement | Per policy |

After rotation: re-enroll the new master public key on all servers.

### Standard PQ key rotation

| Scenario | Rotate |
|----------|--------|
| Personal / low-risk | 6 months |
| Enterprise | 90 days (enforced by `KEY_MAX_AGE_DAYS`) |
| CI/CD automation | 90 days |
| Post compromise | Immediately |

---

## Algorithm performance

### Key and signature sizes

| Algorithm | Public key | Signature | Level |
|-----------|-----------|-----------|-------|
| Ed25519 | 32 B | 64 B | N/A |
| `ssh-falcon1024` | 1,793 B | 1,280 B | 5 |
| `ssh-mldsa-87` (ML-DSA-87) | 2,592 B | 4,627 B | 5 |
| `ssh-sphincssha2256fsimple` | 64 B | 29,792 B | 5 |

### OTK-PQ overhead

Per-session overhead from the OTK-PQ architecture:

| Operation | Approximate time |
|-----------|-----------------|
| Session key generation (Ed25519 + ML-DSA-87) | ~15 ms |
| Master key signing | ~0.5 ms |
| Session ID computation (SHA3-256) | < 1 ms |
| Nonce generation | < 1 ms |
| Secure destruction (3-pass shred) | ~5 ms |
| **Total OTK overhead** | **~25 ms per session** |

This overhead is negligible for interactive SSH sessions.

---

## CVE advisories

### liboqs

| CVE | Fixed in | Description |
|-----|----------|-------------|
| CVE-2024-36405 | 0.10.1 | KyberSlash: timing leak in Kyber/ML-KEM decapsulation |
| CVE-2024-54137 | 0.12.0 | HQC incorrect shared secret on invalid ciphertext |
| CVE-2025-48946 | 0.14.0 | HQC implicit rejection collision |
| CVE-2025-52473 | 0.14.0 | HQC secret-dependent branches |

**Recommendation:** build against liboqs `main` (>= 0.14.0) or the latest tagged release.

### OQS-OpenSSH (upstream inherited)

| CVE | CVSS | Description |
|-----|------|-------------|
| CVE-2024-6387 | 8.1 | "regreSSHion" — unauthenticated RCE |
| CVE-2024-6409 | 7.0 | Race condition RCE in privsep child |
| CVE-2025-26465 | 6.8 | Client MitM if `VerifyHostKeyDNS=yes` |
| CVE-2025-26466 | 5.9 | Pre-auth CPU/memory DoS |

> The OQS-OpenSSH repository (`OQS-v9` branch) is archived. It may not have received patches for all upstream CVEs.

---

## Known limitations

1. **OQS implementations are not yet FIPS-validated.** Await formal FIPS 204/203 certification for regulated environments.

2. **Initial enrollment must be secure.** If the first master key transfer is compromised, the system is broken. This is a bootstrapping problem common to all PKI.

3. **Revocation ledger growth.** The server must maintain a record of used keys. Mitigated by time-based pruning (7-day default).

4. **Client device compromise.** If the master private key is extracted, the system is broken. Hardware-backed storage mitigates this.

5. **Computational overhead.** Generating fresh hybrid keys per session has a cost (~25 ms). Acceptable for SSH, potentially challenging for high-frequency connections.

6. **System SSH is unmodified.** Both standard and post-quantum sshd run simultaneously by default. Firewall the classical SSH port.

7. **OQS-OpenSSH is archived.** The upstream project is no longer actively maintained. This toolkit is built on a research-grade fork.

---

## Incident response

### Suspected master key compromise

1. **Immediately rotate the master key:**
   ```bash
   bash client/otk/master_key.sh rotate
   ```
2. **Re-enroll on all servers:**
   ```bash
   bash client/otk/master_key.sh export > new_master.pub
   bash server/otk/otk_server.sh enroll alice new_master.pub
   ```
3. **Revoke the old enrollment** (if a separate client name was used)
4. **Review server logs** for unusual session activity

### Suspected session key interception

No action required — the session key is already destroyed and revoked. An intercepted session key has zero value.

### Suspected server compromise

1. Stop the sshd: `sudo systemctl stop evaemon-sshd.service`
2. Use out-of-band console access for investigation
3. After remediation:
   - Wipe and rebuild the server
   - Re-initialize the OTK-PQ server: `bash server/otk/otk_server.sh setup`
   - Re-enroll all client master keys
   - Rotate all client master keys (optional but recommended)

### Stale session cleanup

If sessions were interrupted (crash, network failure), clean up residual key material:

```bash
bash client/otk/otk_lifecycle.sh cleanup
```
