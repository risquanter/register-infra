# SOPS + YubiKey Two-Recipient Encryption Model

Hardware-backed secret management for a GitOps repository using SOPS, age, and
`age-plugin-yubikey`. This is the **why-it-is-safe reference**; the operational
runbook (install, generate, encrypt, apply) is
[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md).

- **Goal**: the day-to-day private key is hardware-bound and never sits on disk;
  losing that key never strands the ciphertext
- **Pattern**: two-recipient encryption — a **primary YubiKey** (on-chip,
  touch-to-use) and an **offline backup age key** (recovery only)
- **Prerequisite**: YubiKey 4 or 5 series with PIV support
- **Decryption is manual**: the operator runs `sops -d | kubectl apply` with a
  YubiKey touch. ArgoCD has no SOPS plugin and never decrypts, so no age private
  key is ever placed inside the cluster

> **When to adopt this?** Now — it is the default for both local dev and
> production. Two recipients cost one extra offline keypair and remove the
> single-key failure where losing one key strands every secret. A single
> recipient is acceptable only for a throwaway cluster whose encrypted values
> are all regenerable. See [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) for the
> integration point.

---

## How SOPS encrypts a file (the primitive)

SOPS uses **hybrid encryption**. There are two stages, not one:

```
Step 1:  DATA_KEY = random_256_bits()
Step 2:  ENC_PAYLOAD = AES256_GCM(DATA_KEY, plaintext_secret_values)
Step 3a: ENC_DK_FOR_A = age_encrypt(PUBLIC_KEY_A, DATA_KEY)   # primary (YubiKey)
Step 3b: ENC_DK_FOR_B = age_encrypt(PUBLIC_KEY_B, DATA_KEY)   # backup (offline)
```

**One file. One encrypted payload. Two encrypted copies of the same data key.**

The `.enc.yaml` file committed to git contains all three pieces:

```yaml
postgres-password: ENC[AES256_GCM,data:abc123...]   # ← ENC_PAYLOAD (one copy)
sops:
    age:
        - recipient: age1yubikey1q...                 # ← Recipient A (primary YubiKey)
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----       # ← ENC_DK_FOR_A
            YWdlLWVuY3J5cHRpb24...
            -----END AGE ENCRYPTED FILE-----
        - recipient: age1...                           # ← Recipient B (offline backup)
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----       # ← ENC_DK_FOR_B
            bG9yZW0gaXBzdW0gZG9...
            -----END AGE ENCRYPTED FILE-----
```

To decrypt, you need **only one** of the private keys:

```
# Path A (you, day-to-day, with the YubiKey):
DATA_KEY = age_decrypt(YUBIKEY_PRIVATE, ENC_DK_FOR_A)
plaintext = AES256_GCM_decrypt(DATA_KEY, ENC_PAYLOAD)

# Path B (recovery only, with the offline backup key):
DATA_KEY = age_decrypt(BACKUP_PRIVATE, ENC_DK_FOR_B)
plaintext = AES256_GCM_decrypt(DATA_KEY, ENC_PAYLOAD)
```

Both paths recover the **same DATA_KEY**, which decrypts the **same payload**.
The two recipients share nothing — different key pairs, different encrypted
blobs. They just happen to protect the same symmetric key.

> **Two different age primitives.** A native age keypair (`age-keygen`, the
> backup) uses **X25519** ECDH. The YubiKey recipient uses the PIV applet's
> **NIST P-256** ECDH performed on-chip. Both wrap the same AES-256-GCM data
> key; only the key-agreement curve differs.

---

## Primitives used in the workflow

```
generate_age_keypair_yubikey()  → (PUB_YK, PRIV_YK_on_chip)
   # PRIV_YK never leaves the YubiKey hardware. PUB_YK is printable.

generate_age_keypair_software() → (PUB_BK, PRIV_BK_file)
   # The backup keypair. PRIV_BK is recorded OFFLINE, then removed from disk.

sops_encrypt(file, [PUB_YK, PUB_BK]) → encrypted_file
   # Internally: generates DATA_KEY, encrypts it to each public key.
   # Only needs public keys. No private keys involved.

sops_decrypt_yubikey(encrypted_file, PRIV_YK_on_chip) → plaintext
   # YubiKey performs decryption on-chip. Requires physical touch.

sops_decrypt_backup(encrypted_file, PRIV_BK_file)     → plaintext
   # Recovery path only: software decryption using the restored backup key.

kubectl_apply(plaintext)   → Kubernetes Secret in cluster
```

---

## Use cases

### Use Case 1: Initial setup (once ever)

```
# Step 1: Generate the primary YubiKey identity
(PUB_YK, PRIV_YK_on_chip) = generate_age_keypair_yubikey()
# PUB_YK = "age1yubikey1qf8t3..." — printable recipient
# PRIV_YK_on_chip — sealed inside the YubiKey, cannot be read

# Step 2: Generate the offline backup keypair
(PUB_BK, PRIV_BK_file) = generate_age_keypair_software()
# PUB_BK = "age1abc..." — printable recipient
# PRIV_BK_file = "AGE-SECRET-KEY-1XYZ..." — recorded OFFLINE (paper / USB), then rm

# Step 3: Configure .sops.yaml with BOTH public keys
write_file(".sops.yaml", { recipients: [PUB_YK, PUB_BK] })
```

The backup private key is **not** stored in the repo and **not** injected into
any cluster. It lives off-machine and is touched only during a recovery.

### Use Case 2: Encrypt an application secret (e.g., postgres password)

```
plaintext = { kind: Secret, metadata: { name: postgres-credentials },
              stringData: { postgres-password: "hunter2" } }

sops_encrypt("infra/secrets/postgres.enc.yaml",
    content: plaintext, recipients: [PUB_YK, PUB_BK])   # ← BOTH recipients

# Result committed to git:
#   ENC_PAYLOAD   (postgres-password encrypted with a random DATA_KEY)
#   ENC_DK_FOR_YK (DATA_KEY encrypted to PUB_YK)
#   ENC_DK_FOR_BK (DATA_KEY encrypted to PUB_BK)
```

### Use Case 3: Apply secrets to a cluster (manual, with the YubiKey)

```
# The operator decrypts each file with the YubiKey and pipes it to kubectl.
plaintext = sops_decrypt_yubikey("infra/secrets/postgres.enc.yaml", PRIV_YK_on_chip)
# YubiKey LED blinks → you touch it → decryption happens
kubectl_apply(plaintext)   # plaintext exists only in the pipe

# There is NO cluster-side age key and NO ArgoCD decryption. Repeat on every
# cluster (re)creation. See SECRETS-BOOTSTRAP.md §6.
```

### Use Case 4: Inspect a secret locally (dev work)

```
plaintext = sops_decrypt_yubikey("infra/secrets/postgres.enc.yaml", PRIV_YK_on_chip)
# YubiKey LED blinks → touch → you see "hunter2". Backup key not involved.
```

### Use Case 5: YubiKey lost or dead (recovery)

```
# Restore the backup private key from offline storage and decrypt with it:
PRIV_BK_file = restore_from_offline()
plaintext = sops_decrypt_backup("infra/secrets/postgres.enc.yaml", PRIV_BK_file)
kubectl_apply(plaintext)

# Then re-establish two recipients on a new YubiKey: generate a new identity,
# update the first recipient in .sops.yaml, and `sops updatekeys` across the
# files. Remove the backup key from the machine again afterward.
```

### Use Case 6: Laptop stolen

```
# Attacker has:
#   - Full git clone: all .enc.yaml files and .sops.yaml (public keys)
#
# Attacker can decrypt:        NOTHING
#
# Why:
#   - postgres.enc.yaml needs PRIV_YK (on the YubiKey) or PRIV_BK (offline)
#   - the YubiKey is in your pocket; PRIV_YK is non-exportable and needs PIN + touch
#   - the backup key is off-machine, not on the stolen laptop
```

---

## What lives where

```
┌──────────────────────────────┬──────────────────────────────────┐
│         ARTIFACT             │           LOCATION               │
├──────────────────────────────┼──────────────────────────────────┤
│ PUB_YK  (primary public)     │ .sops.yaml (public, in repo)    │
│ PUB_BK  (backup public)      │ .sops.yaml (public, in repo)    │
│ PRIV_YK (primary private)    │ YubiKey chip (non-exportable)   │
│ PRIV_BK (backup private)     │ Offline only (paper / USB)      │
│ postgres.enc.yaml            │ Repo (encrypted to both)        │
│ postgres-password plaintext  │ Only inside a running cluster,  │
│                              │ applied manually by the operator │
└──────────────────────────────┴──────────────────────────────────┘
```

There is **no single plaintext file** that unlocks everything, and **no age
private key inside the cluster** — decryption needs either the YubiKey or the
offline backup.

---

## Defense-in-depth layers

| # | Layer | Protects against |
|---|---|---|
| 1 | SOPS at rest: AES-256-GCM payload, data key wrapped per recipient via age (X25519 for the backup, P-256/PIV for the YubiKey) | Repo goes public, git history leak |
| 2 | YubiKey-bound primary key (PIV, non-exportable) | Laptop stolen, disk image forensics |
| 3 | Backup key stored offline, never on a running machine | Both machine and cluster compromise |
| 4 | No age private key in the cluster (manual apply, no ArgoCD plugin) | Cluster / etcd compromise cannot yield the decryption key |
| 5 | YubiKey PIN + physical touch for decryption | Remote attacker with shell access |

**Why a backup recipient rather than an in-cluster software key.** An earlier
design put a software key inside the cluster so ArgoCD could decrypt
autonomously. This project does not: no SOPS plugin is configured in
repo-server, and secrets are applied by hand. That removes the weakest layer
(a plaintext key living in etcd) entirely. The remaining single-key risk —
losing the one YubiKey — is covered by the offline backup recipient, which is
never exposed to any running system.

---

## Tool installation and identity generation

The operational steps (install `age-plugin-yubikey`, harden the PIV applet,
generate the on-chip identity with PIN policy `once` / touch policy `always`,
generate the offline backup, write `.sops.yaml`) are in
[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md). This document is the model and
threat reasoning behind them.

---

## References

- [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey) — the plugin
- [SOPS](https://github.com/getsops/sops) — Secrets OPerationS
- [age](https://age-encryption.org/) — the encryption tool
- [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) — the operational runbook
- [ADR-INFRA-006](adr/ADR-INFRA-006.md) — per-namespace secret split and rotation policy
