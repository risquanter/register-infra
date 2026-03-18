# ADR-INFRA-003: AppProject Scoping — Least-Privilege ArgoCD Boundaries

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** argocd, rbac, least-privilege, appproject

---

## Context

- ArgoCD's built-in `default` AppProject allows any Application to deploy any resource kind to any namespace on any cluster — no blast-radius containment
- A misconfigured Application path or namespace could deploy resources into `kube-system`, `istio-system`, or overwrite other services
- When ArgoCD SSO is added, AppProjects are the unit of RBAC — mapping OIDC groups to project roles requires projects to exist
- Four distinct concerns exist: platform (namespaces, mesh policy, RBAC), infrastructure (databases, identity), application (the register service), admission control (Kyverno operator — CRDs, webhooks, cluster RBAC)

---

## Decision

### 1. One AppProject Per Concern

Four AppProjects replace `default`:

| Project | Apps | Allowed Namespaces | Cluster-Scoped Kinds |
|---------|------|--------------------|---------------------|
| `platform` | namespaces, mesh-policy, opa | default, register, argocd, istio-system, infra | Namespace, ClusterPolicy |
| `infra` | postgresql, keycloak | infra | None |
| `app` | register | register | None |
| `kyverno` | kyverno | kyverno | CRD, MutatingWebhookConfiguration, ValidatingWebhookConfiguration, ClusterRole, ClusterRoleBinding |

### 2. Explicit Resource Kind Whitelists

Each project declares exactly which resource kinds it may create. No wildcards.

```yaml
namespaceResourceWhitelist:
  - group: apps
    kind: Deployment
  - group: ""
    kind: Service
  # ... only what the project's charts actually create
```

### 3. Root App Stays in `default`

The root App of Apps must create Application and AppProject resources in the argocd namespace. It is the only Application that uses `project: default`.

---

## Code Smells

### ❌ All Apps in Default Project

```yaml
# BAD: register app can deploy to any namespace
spec:
  project: default
```

```yaml
# GOOD: register app restricted to register namespace, limited resource kinds
spec:
  project: app
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/argocd/projects/platform.yaml` | Platform project definition |
| `infra/argocd/projects/infra.yaml` | Infrastructure project definition |
| `infra/argocd/projects/app.yaml` | Application project definition |
| `infra/argocd/projects/kyverno.yaml` | Kyverno operator project — CRDs, webhooks, RBAC (ADR-INFRA-008) |
| `infra/argocd/apps/*.yaml` | Each Application references its scoped project |

---

## References

- ArgoCD Projects: https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Security review finding C3 (all apps in default project)
- [ADR-INFRA-011](ADR-INFRA-011.md) — in-cluster CI runner (ARC) requires AppProject coverage for runner namespace
