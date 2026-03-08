#!/bin/bash

# OTK-PQ Configuration — One-Time Key Post-Quantum Hybrid Authentication
#
# Extends the base Evaemon config with OTK-specific paths, algorithms,
# and operational parameters for the three-layer architecture:
#   Layer 1 — Post-Quantum Master Key (Anchor)
#   Layer 2 — Hybrid Session Key Generation
#   Layer 3 — One-Time Execution & Destruction

# Source the base config (provides PROJECT_ROOT, BUILD_DIR, BIN_DIR, SSH_DIR, etc.)
SCRIPT_DIR_OTK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_OTK}/config.sh"

# ── OTK Directory Layout ────────────────────────────────────────────────────

# Master key storage — client-side only, never transmitted.
OTK_MASTER_DIR="${SSH_DIR}/otk/master"

# Ephemeral session key working directory — keys live here briefly during
# a single session, then are destroyed.
OTK_SESSION_DIR="${SSH_DIR}/otk/sessions"

# Server-side directory for enrolled master public keys (one per client).
OTK_SERVER_ENROLLED_DIR="${BUILD_DIR}/etc/otk/enrolled"

# Revocation ledger directory — server-side record of used session key hashes.
OTK_LEDGER_DIR="${BUILD_DIR}/etc/otk/ledger"
OTK_LEDGER_FILE="${OTK_LEDGER_DIR}/revocation.ledger"
OTK_LEDGER_LOCK="${OTK_LEDGER_DIR}/.ledger.lock"

# ── Layer 1: Master Key Algorithms ──────────────────────────────────────────

# ML-DSA-87 (FIPS 204) — post-quantum digital signature for master key signing.
# Used to sign ephemeral session keys, proving they originate from the
# legitimate client.  Level 5 security.
OTK_MASTER_SIGN_ALGO="ssh-mldsa-87"

# ML-KEM-1024 (FIPS 203) — post-quantum key encapsulation for master key
# exchange during initial enrollment.  Level 5 security.
OTK_MASTER_KEM_ALGO="mlkem1024-sha384"

# Master key file names (within OTK_MASTER_DIR).
OTK_MASTER_SIGN_KEY="otk_master_sign"
OTK_MASTER_SIGN_PUB="otk_master_sign.pub"

# ── Layer 2: Session Key Algorithms ─────────────────────────────────────────

# Classical component — Ed25519 for signing, X25519 for key exchange.
OTK_SESSION_CLASSICAL_SIGN="ed25519"
OTK_SESSION_CLASSICAL_KEX="curve25519-sha256"

# Post-quantum component — ML-KEM-1024 for session key encapsulation.
OTK_SESSION_PQ_KEX="mlkem1024nistp384-sha384"

# Hybrid KEX list for OTK sessions (PQ first, then classical fallback).
OTK_SESSION_KEX_LIST="${OTK_SESSION_PQ_KEX},mlkem768x25519-sha256,${OTK_SESSION_CLASSICAL_KEX}"

# Session KDF — HKDF-SHA-512 (RFC 5869) for deriving the final session key
# from combined classical + post-quantum shared secrets.
OTK_SESSION_KDF="SHA-512"

# ── Layer 3: One-Time Execution Parameters ──────────────────────────────────

# Maximum nonce age in seconds — session bundles older than this are rejected.
# Default: 300 seconds (5 minutes) to account for clock skew.
OTK_NONCE_MAX_AGE="${OTK_NONCE_MAX_AGE:-300}"

# Nonce random component length in bytes.
OTK_NONCE_RANDOM_BYTES="${OTK_NONCE_RANDOM_BYTES:-32}"

# Revocation ledger pruning — entries older than this (in days) are removed.
# Once a session key is older than this, it would be rejected by nonce
# timestamp validation anyway, so keeping the ledger entry is unnecessary.
OTK_LEDGER_PRUNE_DAYS="${OTK_LEDGER_PRUNE_DAYS:-7}"

# Maximum ledger size (number of entries) before forced pruning.
OTK_LEDGER_MAX_ENTRIES="${OTK_LEDGER_MAX_ENTRIES:-100000}"

# Revocation hashing algorithm — SHA3-256 (FIPS 202).
# Used to hash session keys before storing in the revocation ledger.
OTK_REVOCATION_HASH="sha3-256"

# Secure deletion — number of overwrite passes for key material.
OTK_SHRED_PASSES="${OTK_SHRED_PASSES:-3}"

# ── Session Bundle Format ────────────────────────────────────────────────────
# A session bundle is a directory containing:
#   session_key        — ephemeral private key (Ed25519)
#   session_key.pub    — ephemeral public key
#   session_pq_key     — ephemeral PQ key (for hybrid auth)
#   session_pq_key.pub — ephemeral PQ public key
#   master_signature   — ML-DSA-87 signature over session public keys
#   nonce              — timestamp + random component
#   session_id         — unique session identifier (SHA3-256 of nonce)

# ── Master Key Rotation ─────────────────────────────────────────────────────

# Master key maximum age in days before re-enrollment is recommended.
OTK_MASTER_MAX_AGE_DAYS="${OTK_MASTER_MAX_AGE_DAYS:-365}"

# ── Permissions ──────────────────────────────────────────────────────────────

# Strict permissions for OTK directories and files.
OTK_DIR_PERMS="700"
OTK_PRIVATE_KEY_PERMS="600"
OTK_PUBLIC_KEY_PERMS="644"
OTK_LEDGER_PERMS="600"
