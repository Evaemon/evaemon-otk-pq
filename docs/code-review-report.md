# Evaemon OTK-PQ — Code Review Rapport

**Datum:** 2026-03-08
**Project:** evaemon-otk-pq (One-Time Key Post-Quantum Hybrid SSH Authentication)
**Reviewer:** Claude (AI-assisted review)
**Aangevraagd door:** Yarpii

---

## Samenvatting

Het evaemon-otk-pq project is een goed gestructureerd en veilig systeem voor post-quantum SSH-authenticatie met one-time keys. De codebase bestaat uit ~2.949 regels productiecode verdeeld over 28 shell scripts, met 349+ tests in 18 testbestanden.

**Overall scores:**

| Categorie        | Score  | Opmerking                                      |
|------------------|--------|-------------------------------------------------|
| Error Handling   | 8/10   | `set -eo pipefail` overal, goede validatie      |
| Security         | 9/10   | Permissions, secure delete, geen hardcoded secrets |
| Test Coverage    | 9/10   | 349+ tests, 18 test files                       |
| Cryptografie     | 9/10   | ML-DSA-87, ML-KEM-1024, SHA3-256, Ed25519 hybrid |
| Documentatie     | 9/10   | Goede README, threat model, architectuur         |
| Code Quality     | 8/10   | Consistent style, goede naamgeving               |
| Performance      | 7/10   | Adequaat, schaalbaarheid aandachtspunt bij ledger |
| Onderhoud        | 8/10   | Goede scheiding van concerns                     |

---

## Positieve Bevindingen

### Error Handling & Shell Safety (Uitstekend)
- Universeel gebruik van `set -eo pipefail` in productiescripts
- Proper gebruik van `set +e` in tests voor verwachte failures
- Uitgebreide validatielaag (`shared/validation.sh`) — 193 regels inputvalidatie
- Alle gebruikersinvoer wordt gevalideerd vóór gebruik

### Security Best Practices (Uitstekend)
- Strikte permissie-handhaving: `700` voor directories, `600` voor private keys, `644` voor public keys
- Secure deletion via multi-pass overwrite (`shred` met fallback naar `dd if=/dev/urandom`)
- Master keys opgeslagen met `600` permissies; afgedwongen door de hele codebase
- Revocation ledger met file-level locking (`flock`) tegen concurrent write corruption
- Geen hardcoded credentials of secrets
- Geen `eval` of dynamische code execution kwetsbaarheden gevonden

### Cryptografische Implementatie (Sterk)
- Gebruikt FIPS-goedgekeurde algoritmen: ML-DSA-87 (FIPS 204), ML-KEM-1024 (FIPS 203), SHA3-256 (FIPS 202)
- Hybrid classical+PQ aanpak (Ed25519 + ML-DSA-87)
- Proper nonce-generatie: `timestamp:hex(random)` met 32 bytes (256 bits) CSPRNG
- Session ID afgeleid via SHA3-256(nonce + pubkeys)
- Signature verificatie via `ssh-keygen -Y verify` (standaard OpenSSH)

### Test Coverage (Uitgebreid)
- 334+ unit tests verdeeld over 17 testbestanden
- Tests voor: OTK configuratie (33), session keys (18), lifecycle (17), master keys (15), revocation (20)
- Validatie (44), logging (26), functions (13), en meer
- Integratie tests voor keygen, server setup, key rotation
- Tests draaien zonder OQS binaries (mock-friendly design)

### Logging & Observability (Uitstekend)
- Gecentraliseerde logging module met levels: DEBUG, INFO, WARN, ERROR
- Terminal injection bescherming: `printf '%s\n'` in plaats van `echo -e`
- ANSI kleurcodes gedefinieerd met `$'...'` quoting om injectie te voorkomen
- Optionele file logging met timestamp en level

---

## Gevonden Issues

### HOOG PRIORITEIT

#### 1. Script Injection via Remote Command Execution
- **Bestanden:** `client/otk/otk_connect.sh`, regels ~177-207 en ~237-250
- **Ernst:** Medium-Hoog
- **Probleem:** Het remote script wordt opgebouwd met string substitutie van user-controlled data:
  ```bash
  remote_script="${remote_script//__SESSION_PUB__/${session_pub_content}}"
  ```
  Als `session_pub_content` shell-metacharacters bevat (`$(`, backticks), kunnen die als shell-commando's geïnterpreteerd worden op de remote server.
- **Remedie:** Base64-encode de key content vóór injectie in het remote script, of gebruik `printf '%s'` met proper escaping. Beide remote scripts (verificatie en cleanup) moeten aangepast worden.
- **Status:** Opgelost ✅

#### 2. Geen Validatie van Enrolled Public Keys
- **Bestand:** `server/otk/otk_server.sh` — `enroll_master_key()`
- **Ernst:** Medium-Hoog
- **Probleem:** De functie accepteert elk bestandsinhoud als public key zonder te verifiëren dat het een valide SSH key is. Een corrupt of kwaadaardig bestand kan opgeslagen worden als "enrolled" master key.
- **Remedie:** Voer `ssh-keygen -l -f` uit om het formaat te valideren vóór opslag. Check ook of het key-type overeenkomt met het verwachte algoritme (ML-DSA-87).
- **Status:** Opgelost ✅

---

### MEDIUM PRIORITEIT

#### 3. Temp-file Cleanup Ontbreekt bij Abnormale Exit
- **Bestanden:** `server/otk/revocation_ledger.sh` (regel ~140), `client/otk/otk_connect.sh` (regels ~243-244)
- **Ernst:** Medium
- **Probleem:** `mktemp` wordt gebruikt maar er is geen `trap` voor cleanup bij crash, kill, of interrupt.
- **Remedie:** Voeg `trap 'rm -f "${tmp_file}"' EXIT RETURN` toe direct na elke `mktemp` aanroep.
- **Status:** Opgelost ✅

#### 4. Base64 Encoding Compatibiliteit (GNU vs BSD)
- **Bestand:** `client/otk/otk_connect.sh`, regel ~166
- **Ernst:** Medium
- **Probleem:** Fallback van `base64 -w 0` (GNU) naar `base64` (BSD) kan line-wrapping produceren, wat signature verificatie kan breken.
- **Remedie:** Gebruik `base64 -w 0 2>/dev/null || base64 | tr -d '\n'` als portable oplossing.
- **Status:** Opgelost ✅

#### 5. Betere Foutmeldingen bij Nonce Validatie / Clock Skew
- **Probleem:** Server weigert sessions bij klok-verschil >300s, maar de foutmelding maakt niet duidelijk dat het om clock skew gaat.
- **Remedie:** Specifieke melding: "Clock skew detected: client time differs by Xs from server".
- **Status:** Opgelost ✅

#### 6. Validatie van Session Key Materiaal op Server
- **Bestand:** `server/otk/otk_server.sh`, regels ~159-249
- **Ernst:** Medium
- **Probleem:** Session bundle verificatie controleert niet of public keys het verwachte formaat hebben voordat ze geschreven worden.
- **Remedie:** Regex-check op key formaat (bijv. `ssh-mldsa-87 AAAA...`).
- **Status:** Opgelost ✅

---

### LAAG PRIORITEIT

#### 7. Lange Functies Opsplitsen
- `_push_and_connect()` was 150+ regels — opgesplitst in drie gerichte functies:
  - `_find_bootstrap_key()` — zoekt een bruikbare bootstrap sleutel (PQ of klassiek)
  - `_execute_remote_verification()` — installeert de ephemeral session key op de server
  - `_cleanup_session()` — verwijdert de ephemeral key na afloop van de sessie
- **Status:** Opgelost ✅

#### 8. Disk-Full Handling bij Secure Delete
- `_secure_delete()` faalt stil als de disk vol is tijdens multi-pass overwrite.
- **Remedie:** Voeg check + warning toe.
- **Status:** Opgelost ✅

#### 9. Interrupted Master Key Generatie
- Als `ssh-keygen` halverwege wordt afgebroken, kan een partieel key-bestand achterblijven.
- **Remedie:** Check op incomplete bestanden bij startup.
- **Status:** Opgelost ✅

#### 10. Revocation Ledger Schaalbaarheid
- Default max: 100.000 entries met 10s flock timeout.
- Bij hoge load (>1000 concurrent sessions) kan lock contention optreden.
- **Overweging:** Database backend of sharding voor productie-omgevingen.
- **Status:** Open (architectuur — niet van toepassing op huidige use case)

#### 11. StrictHostKeyChecking=accept-new Documenteren
- Auto-accept van onbekende hosts is verwacht gedrag voor OTK, maar moet duidelijker gedocumenteerd worden (MITM risico bij eerste connectie).
- **Status:** Opgelost ✅

#### 12. Exit Codes Documenteren
- Functies retourneren 0/1 maar de betekenis is niet altijd gedocumenteerd in commentaar.
- Alle publieke functies in de OTK scripts hebben nu een `# Returns ...` regel in hun header:
  `otk_connect.sh`, `session_key.sh`, `otk_lifecycle.sh`, `otk_server.sh`,
  `revocation_ledger.sh`, `master_key.sh`
- **Status:** Opgelost ✅

---

## Compliance & Standaarden

| Standaard | Status | Gebruik |
|-----------|--------|---------|
| NIST FIPS 204 (ML-DSA) | ✅ Conform | Master key signing |
| NIST FIPS 203 (ML-KEM) | ✅ Conform | Key encapsulation |
| NIST FIPS 202 (SHA3) | ✅ Conform | Revocation hashing |
| RFC 5869 (HKDF) | ✅ Conform | Key derivation |
| RFC 8032 (Ed25519) | ✅ Conform | Classical signing |
| RFC 7748 (Curve25519) | ✅ Conform | Classical KEX |

---

## Aanbevolen Acties (Prioriteitsvolgorde)

1. **HOOG:** Fix script injection in `otk_connect.sh` — base64-encode remote script argumenten
2. **HOOG:** Voeg validatie toe dat enrolled public keys valide SSH keys zijn
3. **MEDIUM:** Voeg traps toe voor temp-file cleanup in `revocation_ledger.sh` en `otk_connect.sh`
4. **MEDIUM:** Fix base64 compatibiliteit (GNU/BSD) met `tr -d '\n'` fallback
5. **MEDIUM:** Verbeter nonce validatie foutmeldingen om clock skew te detecteren
6. ~~**LAAG:** Refactor lange functies (>100 regels) naar kleinere eenheden~~ ✅ Opgelost
7. ~~**LAAG:** Documenteer exit codes voor alle publieke functies~~ ✅ Opgelost

---

*Dit rapport is gegenereerd als onderdeel van een code review sessie voor het evaemon-otk-pq project.*
