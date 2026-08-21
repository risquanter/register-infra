# Secrets Bootstrap — SOPS + age + YubiKey

Shared secrets workflow for every point (any cluster, any image repo). The
encrypted files in `infra/secrets/` are the single source of truth — this doc is
where you create them, and where you apply them to a freshly bootstrapped cluster.
The one point-dependent step is the `ghcr-pull` image pull secret, needed only for
the GHCR points (2 and 3) — see [§5.1](#51-ghcr-pull-secret--ghcr-points-2--3-only).

- **Model**: SOPS encrypts secret values in git; age is the encryption backend;
  a YubiKey holds the primary private key on-chip
- **Recipients**: two by default — the **primary YubiKey** (hardware-bound,
  touch-to-use) and an **offline backup age key** (recovery only)
- **Decryption**: manual — the operator runs `sops -d | kubectl apply` with a
  YubiKey touch. ArgoCD does **not** decrypt secrets (there is no SOPS plugin in
  repo-server), so no age private key is ever injected into the cluster

> **Why read this before the rollout?** The PostgreSQL, Keycloak, and SpiceDB
> workloads read their credentials from Kubernetes Secrets that must exist
> *before* ArgoCD syncs them. You apply these secrets by hand in this doc, then
> hand off to [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md) for the root App-of-Apps.

---

## Where this fits

| Step | Doc |
|---|---|
| Reach Platform Ready — cluster + platform (by-hand **or** automated track) | [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) / [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) |
| **Create + apply the encrypted secrets** | **This guide** |
| Enroll ArgoCD, connect git, apply the root app, run tests | [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md) |

This guide begins at [Platform Ready](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
and is identical on both tracks — the same `sops`/`kubectl` commands regardless of
how the cluster was provisioned.

For the cryptographic model, the primitives (age, PIV, ECDH over P-256), the
threat reasoning, and the key-custody rationale, see
[SOPS-YUBIKEY-MODEL.md](SOPS-YUBIKEY-MODEL.md). This guide is the operational
runbook; that doc is the "why it is safe" reference.

---

## The two-recipient model

SOPS generates a random data key per file, encrypts the file's values with it,
then encrypts that data key **separately to each recipient**. Any one
recipient's private key recovers the data key, so it decrypts the file. A
"recipient" is a public key listed under `age:` in `.sops.yaml`.

The default is **two recipients**:

| Recipient | Private key lives | Used for |
|---|---|---|
| **Primary — YubiKey** | on the YubiKey PIV chip, non-exportable, touch-to-use | day-to-day encrypt/decrypt on your workstation |
| **Backup — offline age key** | printed / on a USB stick, stored off this machine | recovery if the YubiKey is lost or dies |

The backup recipient is the recovery answer to the single-key failure: with only
one recipient, losing that key strands every ciphertext. It is a plain age
keypair whose private key never touches a running machine except during a
recovery. It is **not** an ArgoCD cluster key — nothing automated ever uses it.

> **Dev reduction.** For a throwaway local cluster you *may* run a single
> recipient (YubiKey only) if the encrypted values are all regenerable. The
> default and the production path use two. If you skip the backup, add it before
> any cluster holds data you cannot regenerate.

---

## 0) Install age-plugin-yubikey

> `age` and `sops` are installed by the per-environment prefix
> ([MANUAL-BOOTSTRAP.md §0](MANUAL-BOOTSTRAP.md) /
> [TERRAFORM-BOOTSTRAP.md §0](TERRAFORM-BOOTSTRAP.md)). This doc adds the
> YubiKey plugin, which lets age use the YubiKey's PIV applet. The private key
> is generated **on the chip** — it never exists on disk and cannot be exported.

```bash
# WHAT: pcscd is the smart-card daemon. Required for YubiKey PIV communication.
sudo apt-get install -y pcscd libpcsclite-dev

# WHAT: install the age YubiKey plugin, pinned + checksum-verified.
# SECURITY: verify the checksum against the release page before installing.
AGE_YUBIKEY_VERSION="v0.5.0"
curl -fsSLO "https://github.com/str4d/age-plugin-yubikey/releases/download/${AGE_YUBIKEY_VERSION}/age-plugin-yubikey-${AGE_YUBIKEY_VERSION}-x86_64-linux.tar.gz"
# Compare against the SHA256SUMS published on the release page:
#   https://github.com/str4d/age-plugin-yubikey/releases/tag/v0.5.0
sha256sum age-plugin-yubikey-${AGE_YUBIKEY_VERSION}-x86_64-linux.tar.gz
tar xzf age-plugin-yubikey-${AGE_YUBIKEY_VERSION}-x86_64-linux.tar.gz
sudo install -m755 age-plugin-yubikey/age-plugin-yubikey /usr/local/bin/age-plugin-yubikey
rm -rf age-plugin-yubikey age-plugin-yubikey-${AGE_YUBIKEY_VERSION}-x86_64-linux.tar.gz
age-plugin-yubikey --version
```

---

## 1) Harden the YubiKey PIV applet

> A factory YubiKey ships with well-known default PIV credentials (PIN `123456`,
> PUK `12345678`, and the default management key). The age identity lives in the
> PIV applet, so change these **before** generating the identity — otherwise
> anyone who gets the key briefly can use it with the published defaults.

```bash
# WHAT: change the PIV PIN and PUK from their factory defaults.
# The PIN gates decryption; the PUK unblocks a PIN locked by too many wrong tries.
ykman piv access change-pin
ykman piv access change-puk

# WHAT: rotate the PIV management key off the default and protect it with the PIN,
# so it is stored on-card and not needed on the command line each time.
ykman piv access change-management-key --protect --generate
```

> **FIDO2 (GitHub) is separate.** Your GitHub credentials use the FIDO2 applet,
> not PIV, so they are unaffected by the steps above. If the FIDO2 PIN is not
> set, harden it too — `ykman fido access change-pin` — but that is GitHub
> hygiene, not part of the SOPS chain.

---

## 2) Generate the primary YubiKey age identity

```bash
# WHAT: generate a new age identity inside a YubiKey PIV retired slot.
#   The private key is created ON the chip — it never touches disk.
#   The interactive wizard prompts for slot, PIN policy, and touch policy.
# SECURITY: choose PIN policy "once" (PIN once per session) and touch policy
#   "always" (physical touch on every decryption). These are fixed at
#   generation time and cannot be changed afterward without regenerating.
age-plugin-yubikey --generate

# WHAT: print the YubiKey recipient (public key) for .sops.yaml below.
# NOTE: copy this — it looks like: age1yubikey1q...
age-plugin-yubikey --list
```

### Register the YubiKey identity on this machine

`sops` and `age` need a local **identity file** that points at the plugin. Without
it, `sops -d` searches the on-disk age key locations, finds nothing, and fails even
though the YubiKey is attached. Write the identity stub — it is read from the chip,
is **not** the private key, and cannot decrypt anything without the physical YubiKey
plus the PIN and a touch:

```bash
mkdir -p ~/.config/sops/age
age-plugin-yubikey --identity > ~/.config/sops/age/keys.txt
```

This is a **per-machine** step, not a per-key one: repeat it on every workstation
that will decrypt with this YubiKey. See
[Using the YubiKey on another machine](#using-the-yubikey-on-another-machine).

---

## 3) Generate the offline backup age key

```bash
# WHAT: generate a plain age keypair to act as the recovery recipient.
# SECURITY: this private key is the recovery path. It must NOT live on this
#   machine long-term. Generate it, record it offline, then remove the file.
age-keygen -o /tmp/backup-age-key.txt

# NOTE: copy the public key (age1...) from the output for .sops.yaml below.
cat /tmp/backup-age-key.txt   # contains "# public key: age1..." and the secret
```

Store the backup **private** key off this machine — print it and put it in a
safe, or write it to a USB stick kept somewhere separate. Then remove the
working copy:

```bash
# WHAT: remove the plaintext backup key from disk once it is recorded offline.
# NOTE: on tmpfs (/tmp is tmpfs here) the bytes never hit persistent storage;
#   a plain rm is sufficient. Do not rely on `shred` for secure deletion — it
#   does not work on log-structured / copy-on-write / flash-backed filesystems.
rm -f /tmp/backup-age-key.txt
```

> The backup private key is never injected into a cluster and never used by any
> automation. It exists only so that a lost or dead YubiKey does not strand the
> ciphertext — in that case you decrypt with it once and re-provision (see
> [Recovery](#recovery)).

---

## 4) Configure SOPS with both recipients

```bash
# WHAT: tell SOPS to encrypt every file under infra/secrets/ to BOTH recipients.
# HOW IT WORKS: on `sops infra/secrets/foo.enc.yaml`, SOPS creates a random data
#   key, encrypts the values with it, then encrypts that data key once per
#   recipient. Either private key (YubiKey or backup) can recover it.
cat > .sops.yaml <<'YAML'
creation_rules:
  - path_regex: infra/secrets/.*\.yaml$
    age: >-
      age1yubikey1qXXXXXXXXXXXX,
      age1XXXXXXXXXXXXXXXXXXXXXX
YAML
# ↑ First recipient: the YubiKey public key from §2 (age-plugin-yubikey --list)
#   Second recipient: the backup public key from §3
```

Commit `.sops.yaml` — the public keys are not secret:

```bash
git add .sops.yaml
git commit -m "chore: SOPS two-recipient config (YubiKey + offline backup)"
```

---

## 5) Create and encrypt the secret files

`sops` opens your `$EDITOR` with a plaintext YAML file; you write the values,
save, and on exit SOPS encrypts them to both recipients. The YAML **keys** stay
human-readable for review; only the **values** are ciphertext.

The stack uses four secrets. Two live in `infra`, one in `infra` (SpiceDB), and
one in `register`:

```bash
sops infra/secrets/postgres.enc.yaml
```
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: infra
type: Opaque
stringData:
  postgres-password: "POSTGRES_SUPERUSER_PASSWORD"   # PostgreSQL superuser
  keycloak-db-password: "KEYCLOAK_DB_USER_PASSWORD"  # Keycloak's own DB user (distinct from the superuser and the admin-UI password)
```

```bash
sops infra/secrets/keycloak.enc.yaml
```
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
  namespace: infra
type: Opaque
stringData:
  admin-password: "KEYCLOAK_ADMIN_UI_PASSWORD"       # Keycloak web admin console
```

```bash
sops infra/secrets/spicedb.enc.yaml
```
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spicedb-credentials
  namespace: infra
type: Opaque
stringData:
  preshared-key: "SPICEDB_PRESHARED_KEY"             # gRPC auth token for SpiceDB
  db-password: "SPICEDB_DB_PASSWORD"                 # SpiceDB's PostgreSQL datastore role
  datastore-uri: "postgres://spicedb:SPICEDB_DB_PASSWORD@postgresql.infra.svc.cluster.local:5432/spicedb?sslmode=disable"
```

```bash
sops infra/secrets/spicedb-register.enc.yaml
```
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: spicedb-preshared-key-register
  namespace: register            # ← the register app reads it from its own namespace
type: Opaque
stringData:
  spicedb-preshared-key: "SPICEDB_PRESHARED_KEY"     # same token as spicedb's preshared-key, delivered into the register namespace
```

> **Why `spicedb-register` repeats the preshared key.** Kubernetes Secrets are
> namespace-scoped: a pod in `register` cannot read a Secret in `infra`. The
> SpiceDB token therefore appears in two SOPS files targeting two namespaces —
> the same value, expressed twice. This is the GitOps-native pattern (no
> cross-namespace reflector, no external operator). See
> [ADR-INFRA-006](adr/ADR-INFRA-006.md) for the per-namespace secret rationale
> and the future `register-db` credential split.

Verify and commit the ciphertext:

```bash
# VERIFICATION: values are ENC[...] ciphertext, keys are plain, and the sops
#   metadata block shows TWO recipient entries (YubiKey + backup).
cat infra/secrets/postgres.enc.yaml

# Safe to commit — ciphertext is meaningless without one of the private keys.
git add infra/secrets/
git commit -m "chore: add SOPS-encrypted secrets (two-recipient)"
```

### 5.1 GHCR pull secret — GHCR points (2 & 3) only

**Skip this for point 1** (local registry): the k3d registry needs no auth, and
the `register`/`irmin`/`frontend` charts use `values-localreg.yaml`, which sets no
`imagePullSecrets`.

For the GHCR points, the `values-ghcr.yaml` overlays reference an
`imagePullSecrets` entry named `ghcr-pull` in the `register` namespace. GHCR
packages are private by default, so without it the app pods fail with
`ImagePullBackOff` (403 denied). Two ways to satisfy it:

- **Make the packages public** (simplest for a learning setup): in the GitHub
  package settings, set each package's visibility to public. No secret needed —
  but you can still create `ghcr-pull` harmlessly.
- **Create the pull secret** from a GitHub PAT with `read:packages`:

```bash
# The register namespace is created by the namespaces app (GITOPS-ROLLOUT.md);
# apply this after that, before the register/frontend apps sync.
kubectl -n register create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<PAT-with-read:packages>
```

> To keep the PAT in git under the same SOPS model as the other secrets, encrypt
> the rendered `.dockerconfigjson` Secret into `infra/secrets/ghcr-pull.enc.yaml`
> and apply it with `sops -d | kubectl apply` like the others. The PAT itself is
> never committed in plaintext.

---

## 6) Apply the secrets to the cluster

> **Ordering.** Run this at [Platform Ready](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
> (platform up, ArgoCD installed), but **before** the root App-of-Apps
> ([GITOPS-ROLLOUT.md §root-app](GITOPS-ROLLOUT.md)).
> The workloads read these Secrets at startup; they must exist first. The
> `register`-namespace secret can be applied any time before the `register` app
> syncs — the namespaces app creates the `register` namespace, so apply it after
> the namespaces app is healthy or pre-create the namespace as below.

```bash
# WHAT: pre-create the namespaces the Secrets target, so they can be applied
#   before ArgoCD adopts them via the namespaces Helm chart.
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace register --dry-run=client -o yaml | kubectl apply -f -

# WHAT: decrypt each file and apply it. `sops -d` uses the YubiKey — each
#   decryption prompts for a physical touch (touch policy "always").
# SECURITY: the plaintext exists only in the pipe; it is never written to disk
#   or held in a shell variable.
sops -d infra/secrets/postgres.enc.yaml         | kubectl apply -f -
sops -d infra/secrets/keycloak.enc.yaml         | kubectl apply -f -
sops -d infra/secrets/spicedb.enc.yaml          | kubectl apply -f -
sops -d infra/secrets/spicedb-register.enc.yaml | kubectl apply -f -

# VERIFICATION: the Secrets exist with the expected keys.
kubectl -n infra    get secret postgres-credentials     -o jsonpath='{.data}' | jq keys
kubectl -n infra    get secret keycloak-credentials     -o jsonpath='{.data}' | jq keys
kubectl -n infra    get secret spicedb-credentials      -o jsonpath='{.data}' | jq keys
kubectl -n register get secret spicedb-preshared-key-register -o jsonpath='{.data}' | jq keys
```

> **On every cluster recreation** you repeat only this section — the keypairs
> and encrypted files already exist. There is no cluster-side age key to
> re-inject, because ArgoCD never decrypts.

---

## Using the YubiKey on another machine

The YubiKey is portable: any workstation with it attached can encrypt and decrypt,
without repeating the one-time key setup. On a new machine you do **not** re-run
§1–§3 — the identity already lives on the chip, the offline backup already exists,
and `.sops.yaml` ships in the repo. You only make the machine able to talk to the key:

1. Install `age`, `sops`, `age-plugin-yubikey`, and `pcscd` — §0 above plus the tool
   install in the per-environment prefix
   ([MANUAL-BOOTSTRAP.md §0](MANUAL-BOOTSTRAP.md) /
   [TERRAFORM-BOOTSTRAP.md §0](TERRAFORM-BOOTSTRAP.md)).
2. Attach the YubiKey and write the per-machine identity file:
   ```bash
   mkdir -p ~/.config/sops/age
   age-plugin-yubikey --identity > ~/.config/sops/age/keys.txt
   ```
3. Clone the repo and decrypt as usual — `sops -d infra/secrets/<file>.enc.yaml`
   prompts for the PIN and a touch.

The offline backup key is **not** part of per-machine setup: it stays offline and is
used only to recover from a lost or dead YubiKey (see [Recovery](#recovery)).

---

## What lives where

| Artifact | Location | Secret? |
|---|---|---|
| YubiKey private key | YubiKey PIV chip (non-exportable) | yes — hardware-bound |
| Backup private key | offline (paper / USB, off-machine) | yes — recovery only |
| Both public keys | `.sops.yaml` in the repo | no |
| Encrypted secret values | `infra/secrets/*.enc.yaml` in the repo | no — ciphertext |
| Decrypted Kubernetes Secrets | in the cluster (applied in §6) | yes — at rest per env |

There is **no single plaintext file** that unlocks everything. Neither the
YubiKey being present nor the repo being cloned is sufficient alone — decryption
needs a private key, and the only two are the YubiKey and the offline backup.

---

## Recovery

If the YubiKey is lost or fails, the backup recipient decrypts everything:

```bash
# WHAT: import the backup private key (from offline storage) and decrypt with it.
export SOPS_AGE_KEY_FILE=/path/to/restored/backup-age-key.txt
sops -d infra/secrets/postgres.enc.yaml | kubectl apply -f -
# ... etc.
```

Then re-establish the two-recipient model on a new YubiKey: generate a new
identity (§2), update the first recipient in `.sops.yaml`, and
`sops updatekeys infra/secrets/*.enc.yaml` to re-wrap the data keys. Remove the
backup key from the machine again afterward.

> **If both keys are lost**, the ciphertext is unrecoverable — you regenerate
> every secret value from scratch (§5) under fresh recipients. For dev-only
> throwaway values this is cheap; it is the exact failure the backup recipient
> exists to prevent for anything that is not regenerable.

---

## Rotation

To rotate a **value** (e.g. a leaked password): `sops infra/secrets/foo.enc.yaml`,
change the value, save, commit, and re-apply (§6). To rotate a **recipient**
(e.g. new YubiKey): update `.sops.yaml` and run
`sops updatekeys infra/secrets/*.enc.yaml`, which re-encrypts each file's data
key to the new recipient set without changing the values. See
[ADR-INFRA-006](adr/ADR-INFRA-006.md) for the rotation policy.
