# SOPS + YubiKey Dual-Recipient Encryption Model

Hardware-backed secret management for a public GitOps repository using
SOPS, age, and `age-plugin-yubikey`.

- **Goal**: no age private key ever sits as plaintext on disk
- **Pattern**: dual-recipient encryption — YubiKey for humans, software key for ArgoCD
- **Prerequisite**: YubiKey 4 or 5 series with PIV support

> **When to adopt this?** This model is a **go-live hardening step**. During
> local development with k3d, a software-only age key is acceptable — the
> repo is private and the secrets are dev-only throwaway values. Implement
> this before making the repository public or deploying to Hetzner production.
> See [K3S-GITOPS-BOOTSTRAP.md §1.0](K3S-GITOPS-BOOTSTRAP.md) for the
> integration point.

---

## How SOPS encrypts a file (the primitive)

SOPS uses **hybrid encryption**. There are two stages, not one:

```
Step 1:  DATA_KEY = random_256_bits()
Step 2:  ENC_PAYLOAD = symmetric_encrypt(DATA_KEY, plaintext_secret_values)
Step 3a: ENC_DK_FOR_A = age_encrypt(PUBLIC_KEY_A, DATA_KEY)
Step 3b: ENC_DK_FOR_B = age_encrypt(PUBLIC_KEY_B, DATA_KEY)
```

**One file. One encrypted payload. Two encrypted copies of the same data key.**

The `.enc.yaml` file committed to git contains all three pieces:

```yaml
postgres-password: ENC[AES256_GCM,data:abc123...]   # ← ENC_PAYLOAD (one copy)
sops:
    age:
        - recipient: age1yubikey1q...                 # ← Recipient A (YubiKey)
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----       # ← ENC_DK_FOR_A
            YWdlLWVuY3J5cHRpb24...
            -----END AGE ENCRYPTED FILE-----
        - recipient: age1software...                  # ← Recipient B (cluster key)
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----       # ← ENC_DK_FOR_B
            bG9yZW0gaXBzdW0gZG9...
            -----END AGE ENCRYPTED FILE-----
```

To decrypt, you need **only one** of the private keys:

```
# Path A (you, with YubiKey):
DATA_KEY = age_decrypt(YUBIKEY_PRIVATE, ENC_DK_FOR_A)
plaintext = symmetric_decrypt(DATA_KEY, ENC_PAYLOAD)

# Path B (ArgoCD, with software key):
DATA_KEY = age_decrypt(SOFTWARE_PRIVATE, ENC_DK_FOR_B)
plaintext = symmetric_decrypt(DATA_KEY, ENC_PAYLOAD)
```

Both paths recover the **same DATA_KEY**, which decrypts the **same payload**.
The two recipients share nothing — different key pairs, different encrypted
blobs. They just happen to protect the same symmetric key.

---

## Primitives used in the workflow

```
generate_age_keypair_yubikey()  → (PUB_YK, PRIV_YK_on_chip)
   # PRIV_YK never leaves the YubiKey hardware. PUB_YK is printable.

generate_age_keypair_software() → (PUB_SW, PRIV_SW_file)
   # Both are files on disk. PRIV_SW must be protected.

sops_encrypt(file, [PUB_YK, PUB_SW]) → encrypted_file
   # Internally: generates DATA_KEY, encrypts it to each public key.
   # Only needs public keys. No private keys involved.

sops_decrypt_yubikey(encrypted_file, PRIV_YK_on_chip) → plaintext_file
   # YubiKey performs decryption on-chip. Requires physical touch.

sops_decrypt_software(encrypted_file, PRIV_SW_file)   → plaintext_file
   # Pure software decryption using the key file.

kubectl_apply(plaintext_file)   → Kubernetes Secret in cluster
shred(file)                     → secure-delete from disk
```

---

## Use cases

### Use Case 1: Initial setup (once ever)

```
# Step 1: Generate YubiKey identity
(PUB_YK, PRIV_YK_on_chip) = generate_age_keypair_yubikey()
# PUB_YK = "age1yubikey1qf8t3..." — written to screen / identity file
# PRIV_YK_on_chip — sealed inside YubiKey, cannot be read

# Step 2: Generate software key for the cluster
(PUB_SW, PRIV_SW_file) = generate_age_keypair_software()
# PUB_SW = "age1abc..." — written to screen
# PRIV_SW_file = "AGE-SECRET-KEY-1XYZ..." — at /tmp/cluster-key.txt

# Step 3: Configure .sops.yaml with BOTH public keys
write_file(".sops.yaml", {
    recipients: [PUB_YK, PUB_SW]
})

# Step 4: Protect the software private key using the YubiKey
sops_encrypt("cluster-age-key.enc.yaml",
    content:    { "age-key": PRIV_SW_file },
    recipients: [PUB_YK]              # ← ONLY the YubiKey!
)
# Result: cluster-age-key.enc.yaml in repo. Can ONLY be decrypted
#         by someone holding the YubiKey.

# Step 5: Destroy the plaintext software key from disk
shred(PRIV_SW_file)
# PRIV_SW now exists in exactly TWO places:
#   1. Inside cluster-age-key.enc.yaml (encrypted, needs YubiKey to read)
#   2. Nowhere else yet — not in the cluster until Use Case 3
```

### Use Case 2: Encrypt an application secret (e.g., postgres password)

```
# You write a plaintext secret file
plaintext = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": { "name": "postgres-credentials" },
    "stringData": { "postgres-password": "hunter2" }
}

# Encrypt to BOTH recipients
sops_encrypt("infra/secrets/postgres.enc.yaml",
    content:    plaintext,
    recipients: [PUB_YK, PUB_SW]     # ← BOTH recipients
)

# Result on disk (committed to git):
# infra/secrets/postgres.enc.yaml contains:
#   - ENC_PAYLOAD         (postgres-password encrypted with random DATA_KEY)
#   - ENC_DK_FOR_YK       (DATA_KEY encrypted to PUB_YK)
#   - ENC_DK_FOR_SW       (DATA_KEY encrypted to PUB_SW)
```

### Use Case 3: Bootstrap the cluster (after cluster creation)

```
# Step 1: Decrypt the software key using YOUR YubiKey (touch required)
PRIV_SW_plaintext = sops_decrypt_yubikey(
    "cluster-age-key.enc.yaml",
    PRIV_YK_on_chip               # ← YubiKey performs on-chip decryption
)
# YubiKey LED blinks → you touch it → decryption happens

# Step 2: Inject PRIV_SW into the cluster as a Kubernetes Secret
kubectl_apply({
    "kind": "Secret",
    "metadata": { "name": "sops-age-key", "namespace": "argocd" },
    "data": { "keys.txt": PRIV_SW_plaintext }
})

# Step 3: Destroy the plaintext from disk (again)
shred(PRIV_SW_plaintext)

# Now PRIV_SW exists in:
#   1. cluster-age-key.enc.yaml  (encrypted, needs YubiKey)
#   2. Kubernetes Secret          (in memory / etcd inside cluster)
#   3. Nowhere on disk in plaintext
```

### Use Case 4: You decrypt locally (dev work)

```
# You want to inspect a secret value
plaintext = sops_decrypt_yubikey(
    "infra/secrets/postgres.enc.yaml",
    PRIV_YK_on_chip
)
# YubiKey LED blinks → touch → you see "hunter2"
# Software key not involved at all
```

### Use Case 5: ArgoCD auto-syncs at 3 AM

```
# ArgoCD sees infra/secrets/postgres.enc.yaml changed in git
plaintext = sops_decrypt_software(
    "infra/secrets/postgres.enc.yaml",
    PRIV_SW_file  # ← read from sops-age-key Secret in argocd namespace
)
# No YubiKey needed. No human needed.
kubectl_apply(plaintext)
# Cluster has the updated postgres-credentials Secret
```

### Use Case 6: Laptop stolen

```
# Attacker has:
#   - Full git clone (public repo): all .enc.yaml files
#   - cluster-age-key.enc.yaml: encrypted software key
#
# Attacker can decrypt:        NOTHING
#
# Why:
#   - postgres.enc.yaml needs PRIV_YK (on YubiKey) or PRIV_SW (shredded)
#   - cluster-age-key.enc.yaml needs PRIV_YK (on YubiKey)
#   - YubiKey is in your pocket
#   - YubiKey requires PIN + physical touch
#   - PRIV_YK is non-exportable from the chip
```

---

## What lives where

```
┌──────────────────────────────┬──────────────────────────────────┐
│         ARTIFACT             │           LOCATION               │
├──────────────────────────────┼──────────────────────────────────┤
│ PUB_YK                       │ .sops.yaml (public, in repo)    │
│ PUB_SW                       │ .sops.yaml (public, in repo)    │
│ PRIV_YK                      │ YubiKey chip (non-exportable)   │
│ PRIV_SW (encrypted)          │ cluster-age-key.enc.yaml (repo) │
│ PRIV_SW (plaintext)          │ K8s Secret only, shredded       │
│                              │ from disk after injection        │
│ postgres.enc.yaml            │ Repo (encrypted to both)        │
│ postgres-password plaintext  │ Only inside running cluster pod │
└──────────────────────────────┴──────────────────────────────────┘
```

---

## Defense-in-depth layers

| # | Layer | Protects against |
|---|---|---|
| 1 | SOPS encryption at rest (X25519 + ChaCha20-Poly1305) | Repo goes public, git history leak |
| 2 | YubiKey-bound local key (PIV, non-exportable) | Laptop stolen, disk image forensics |
| 3 | Software key encrypted to YubiKey in repo | Repo clone alone is useless |
| 4 | Software key plaintext only inside cluster etcd | No persistent plaintext on dev machine |
| 5 | YubiKey PIN + physical touch for decryption | Remote attacker with shell access |

**The unavoidable concession**: ArgoCD needs autonomous decryption, so a
software key must exist inside the cluster. That key is protected at rest
(encrypted to YubiKey) and in transit (injected once, shredded from disk).
The cluster boundary (k3s etcd encryption in production, Docker container
locally) is the weakest layer — accepted because local secrets are
dev-only throwaway values.

---

## Tool installation

```bash
# pcscd — smart card daemon (required for YubiKey PIV)
sudo apt-get install -y pcscd libpcsclite-dev

# age-plugin-yubikey — age plugin for YubiKey PIV
# Option A: cargo (if Rust toolchain is installed)
cargo install age-plugin-yubikey

# Option B: pre-built binary
# See https://github.com/str4d/age-plugin-yubikey/releases
```

## Generating the YubiKey identity (interactive)

```bash
# This walks you through selecting a PIV slot and setting PIN/touch policy.
# The private key is generated ON the YubiKey — it never exists on disk.
age-plugin-yubikey

# After setup, list the recipient (public key) for .sops.yaml:
age-plugin-yubikey --list
# Output: age1yubikey1q...
```

---

## References

- [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey) — the plugin
- [SOPS](https://github.com/getsops/sops) — Secrets OPerationS
- [age](https://age-encryption.org/) — the encryption tool
- [K3S-GITOPS-BOOTSTRAP.md §1.0](K3S-GITOPS-BOOTSTRAP.md) — Hetzner integration point
