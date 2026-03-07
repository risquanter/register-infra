# ADR-INFRA-006: Application Database Credentials — Per-Namespace SOPS Secrets

**Status:** Accepted  
**Date:** 2026-03-07  
**Tags:** secrets, sops, postgresql, least-privilege, namespace-scoping

---

## Context

- The `postgres-credentials` Secret in the `infra` namespace holds the PostgreSQL superuser password (`postgres-password`) and the Keycloak DB user password (`keycloak-db-password`). Both are consumed exclusively by Bitnami charts deployed in `infra`
- Kubernetes Secrets are namespace-scoped — a pod in `register` cannot reference a Secret in `infra`. Any future service that needs database credentials must have its own Secret in its own namespace
- Least-privilege database access requires per-service roles: the register app should connect as a dedicated `register_app` role with `GRANT` only on its own schema, not as the `postgres` superuser or the `bn_keycloak` user. Sharing the superuser password across services turns a single compromised pod into full DDL/DML over all databases
- The register app currently uses in-memory storage (`TrieMap` / `Ref[Map]`). When `WorkspaceStorePostgres` is implemented, it will need a database password delivered via a Kubernetes Secret. The credential delivery mechanism must be decided before that work begins
- Three approaches were evaluated:
  1. **SOPS-encrypted Secret per namespace** — same tooling already in use
  2. **Reflector operator** — auto-mirrors secrets across namespaces
  3. **External Secrets Operator (ESO)** — reconciles CRDs from an external store

---

## Decision

### Use SOPS-encrypted Secrets per namespace (Approach A)

Each service that needs database credentials gets a **dedicated SOPS-encrypted Secret** in its own namespace. The password is expressed in two SOPS files: one for the PostgreSQL `initdb` configuration (in `infra`), one for the application (in `register`).

### Per-service database roles (least-privilege)

The register app connects as a **dedicated `register_app` PostgreSQL role** with `GRANT` only on its own database/schema. It never sees the superuser password or the Keycloak DB password.

### No new operators

Skip Reflector and ESO. Both require cluster-wide RBAC to read/write Secrets in all namespaces — an excessive privilege surface for a single-node cluster with two namespaces and one database consumer.

---

## Implementation

| Artifact | Namespace | What it contains |
|---|---|---|
| `infra/secrets/postgres.enc.yaml` | `infra` | `postgres-password` (superuser) + `keycloak-db-password` (Keycloak DB user) |
| `infra/secrets/register-db.enc.yaml` | `register` | `register-db-password` (register app DB user) — **created when PG is wired in** |

The Bitnami PostgreSQL chart creates the `register_app` role via `auth.username` / `auth.database` or `initdb` scripts, using the same password value from the `infra`-namespace Secret.

The register Helm chart references only `register-db-credentials` (in `register` namespace):

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: register-db-credentials
        key: register-db-password
```

Password rotation: re-encrypt both SOPS files with the new password, commit, push. ArgoCD applies both Secrets. PostgreSQL `ALTER ROLE` and app restart happen on next sync.

---

## Alternatives Rejected

### Reflector operator (emberstack/kubernetes-reflector)

- **What**: annotate source Secret, operator copies to target namespaces
- **Why rejected**: requires cluster-wide Secret R/W RBAC. A compromised reflector exposes all secrets in all namespaces. Mirrors the admin password rather than provisioning a dedicated role — violates least-privilege. Contradicts ADR-INFRA-003 (least-privilege scoping) and ADR-INFRA-004 (defense-in-depth). Adds a failure mode: silent mirror failure → `CreateContainerConfigError` with no clear cause.

### External Secrets Operator (ESO) with Kubernetes provider

- **What**: ESO `ClusterSecretStore` with `kubernetes` provider reads secrets cross-namespace
- **Why rejected**: designed for external secret managers (Vault, AWS SM, GCP SM). Using the Kubernetes provider to read secrets from the same cluster is architecturally over-engineered for two namespaces. Same RBAC surface as Reflector. Same least-privilege violation (mirrors admin credentials). Could be revisited if HashiCorp Vault is introduced for short-lived dynamic database credentials.

### Single shared Secret (cross-namespace reference)

- **What**: somehow make the `infra` Secret visible to `register`
- **Why rejected**: Kubernetes does not support cross-namespace Secret references. Would require either a shared namespace (breaks isolation) or a custom controller (unnecessary complexity).

---

## Code Smells

### ❌ App referencing infrastructure admin credentials

```yaml
# BAD: register app using the PostgreSQL superuser password
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-credentials           # ← admin secret, wrong namespace
        key: postgres-password               # ← superuser, not least-privilege
```

### ✅ App referencing its own dedicated credentials

```yaml
# GOOD: register app using a scoped, per-service Secret
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: register-db-credentials        # ← register namespace
        key: register-db-password            # ← dedicated register_app role
```

### ❌ Premature wiring (current state)

```yaml
# BAD: DB_* env vars in values.yaml for an app that uses in-memory storage.
# secretKeyRef is a hard dependency — kubelet refuses to start the container
# if the referenced Secret doesn't exist.
env:
  - name: DB_HOST
    value: "postgresql.infra.svc.cluster.local"
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-credentials
        key: postgres-password
```

```yaml
# GOOD: only include DB_* env vars when the app actually uses PostgreSQL.
# Document the future strategy in a comment referencing this ADR.
env:
  - name: KEYCLOAK_ISSUER
    value: "http://keycloak.infra.svc.cluster.local/realms/register"
  # DB_* env vars: see ADR-INFRA-006. Added when WorkspaceStorePostgres lands.
```

---

## References

- ADR-INFRA-003 §2 (explicit resource kind whitelists — least-privilege scoping)
- ADR-INFRA-004 §1 (both NetworkPolicy and PeerAuthentication required — defense-in-depth extends to credential isolation)
- AUTHORIZATION-PLAN.md Phase K.3 (PostgreSQL on K8s — separate DBs/schemas)
- IMPLEMENTATION-PLAN.md DP-9 (in-memory initially, PG follows cheleb patterns)
- [K3S-GITOPS-BOOTSTRAP.md §1.6](../K3S-GITOPS-BOOTSTRAP.md) (implementation steps)
