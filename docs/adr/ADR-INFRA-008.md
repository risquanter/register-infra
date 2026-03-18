# ADR-INFRA-008: Kyverno Admission Mutation — Replacing PostSync Hooks with Policy-Based Pod Patching

**Status:** Accepted  
**Date:** 2026-03-18  
**Tags:** kyverno, pss, admission-controller, seccomp, gitops

---

## Context

- Istio's gateway controller generates waypoint Deployments from an internal template that does NOT include `seccompProfile` in the pod security context
- Namespaces enforcing restricted Pod Security Standards (PSS) reject pods without `seccompProfile.type: RuntimeDefault`, causing waypoint scheduling to fail
- The previous solution — a PostSync `kubectl patch` Job — was fragile: container image removal by vendor caused `ImagePullBackOff`, and Job lifecycle issues stalled ArgoCD syncs indefinitely
- Admission mutation applies at pod creation time, before PSS admission evaluation, eliminating the timing gap between pod creation and patch application
- Kyverno is CNCF Graduated and installs cluster-level resources (CRDs, webhooks, ClusterRoles) that must be scoped in a dedicated AppProject to preserve blast-radius containment (ADR-INFRA-003)

---

## Decision

### 1. Kyverno Admission Controller via Upstream Helm Chart

Deploy Kyverno 3.x from the upstream Helm chart (`https://kyverno.github.io/kyverno/`) as an ArgoCD Application. Only the admission controller is enabled — background, cleanup, and reports controllers are disabled to minimise footprint.

```yaml
source:
  repoURL: https://kyverno.github.io/kyverno/
  chart: kyverno
  targetRevision: "3.7.1"
  helm:
    valuesObject:
      admissionController:
        replicas: 1
      backgroundController:
        enabled: false
      cleanupController:
        enabled: false
      reportsController:
        enabled: false
```

### 2. Dedicated `kyverno` AppProject — Operator Isolation

Kyverno's chart installs 22 CRDs, webhook configurations, and cluster-wide RBAC. A dedicated `kyverno` AppProject scopes these permissions, keeping the `platform` project limited to policy instances (ClusterPolicy).

```yaml
# kyverno project — operator-level resources
clusterResourceWhitelist:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
  - group: rbac.authorization.k8s.io
    kind: ClusterRole
  - group: rbac.authorization.k8s.io
    kind: ClusterRoleBinding
destinations:
  - namespace: kyverno

# platform project — policy instances only
clusterResourceWhitelist:
  - group: kyverno.io
    kind: ClusterPolicy
```

### 3. ServerSideApply for CRD Size Limit

Two Kyverno CRDs exceed the 262144-byte `kubectl.kubernetes.io/last-applied-configuration` annotation limit. Server-side apply avoids this annotation entirely.

```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
```

### 4. ClusterPolicy: `inject-seccomp-profile`

A single ClusterPolicy mutates pods in the `register` namespace that lack `seccompProfile.type` at the pod level. The policy uses `failurePolicy: Ignore` — if Kyverno is unavailable, pods are created without mutation and PSS admission rejects them (same behaviour as pre-Kyverno).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-seccomp-profile
spec:
  failurePolicy: Ignore
  rules:
    - name: add-seccomp-profile
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [register]
      preconditions:
        all:
          - key: "{{ request.object.spec.securityContext.seccompProfile.type || '' }}"
            operator: Equals
            value: ""
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              seccompProfile:
                type: RuntimeDefault
```

### 5. Policy Instances via `mesh-policy` App (Platform Project)

The ClusterPolicy manifest lives under `infra/k8s/kyverno/` and is deployed by the `mesh-policy` Application (project: `platform`). This keeps policy instances alongside other security manifests (Istio, NetworkPolicy, RBAC).

---

## Code Smells

### ❌ PostSync kubectl-patch Job for PSS Compliance

```yaml
# BAD: fragile — image removal causes ImagePullBackOff, Job lifecycle stalls ArgoCD.
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
spec:
  template:
    spec:
      containers:
        - name: patcher
          image: registry.k8s.io/kubectl:v1.31.5
          command: ["kubectl", "patch", "deployment", ...]
```

```yaml
# GOOD: admission mutation — instant, no image to pull, no Job lifecycle.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-seccomp-profile
spec:
  failurePolicy: Ignore
  rules:
    - name: add-seccomp-profile
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              seccompProfile:
                type: RuntimeDefault
```

### ❌ Kyverno Operator Permissions in Platform Project

```yaml
# BAD: widens platform blast radius with CRDs, webhooks, ClusterRoles.
# platform project:
clusterResourceWhitelist:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
```

```yaml
# GOOD: dedicated kyverno project for operator; platform keeps only instances.
# kyverno project:
clusterResourceWhitelist:
  - { group: apiextensions.k8s.io, kind: CustomResourceDefinition }
# platform project:
clusterResourceWhitelist:
  - { group: kyverno.io, kind: ClusterPolicy }
```

### ❌ failurePolicy: Fail on Mutation-Only Policy

```yaml
# BAD: Kyverno outage blocks ALL pod creation in matched namespaces.
spec:
  failurePolicy: Fail
```

```yaml
# GOOD: Ignore — PSS admission is the enforcement backstop.
spec:
  failurePolicy: Ignore
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/argocd/apps/kyverno.yaml` | ArgoCD Application — upstream chart, SSA enabled (Decision §1, §3) |
| `infra/argocd/projects/kyverno.yaml` | Dedicated AppProject — CRDs, webhooks, RBAC (Decision §2) |
| `infra/argocd/projects/platform.yaml` | ClusterPolicy in clusterResourceWhitelist (Decision §2) |
| `infra/k8s/kyverno/inject-seccomp-profile.yaml` | ClusterPolicy manifest (Decision §4) |

---

## Alternatives Rejected

### PostSync kubectl-patch Job

- **What**: ArgoCD PostSync hook runs a `kubectl patch` command after each sync to add `seccompProfile` to the waypoint Deployment
- **Why rejected**: fragile image dependency (Broadcom removed `bitnami/kubectl:1.31`), Job lifecycle stalls ArgoCD sync, timing window between pod creation and patch allows PSS rejection. Admission mutation eliminates all three failure modes.

### Gatekeeper (OPA) Mutation

- **What**: use the existing OPA deployment with Gatekeeper mutation webhooks
- **Why rejected**: OPA is deployed as a standalone ext_authz gRPC server (ADR-INFRA-001), not as Gatekeeper. Adding Gatekeeper's admission webhooks would be a separate operator deployment with no reuse of the existing OPA.

---

## Obsolescence Criteria

This ADR and the `inject-seccomp-profile` ClusterPolicy become obsolete when istiod adds `seccompProfile` natively to the waypoint Deployment template. Track upstream: `https://github.com/istio/istio/issues` (search: waypoint seccompProfile restricted PSS). Remove the ClusterPolicy and evaluate decommissioning Kyverno when resolved.

---

## References

- [ADR-INFRA-003](ADR-INFRA-003.md) — AppProject scoping (kyverno project)
- [ADR-INFRA-002](ADR-INFRA-002.md) — fail-closed availability guarantees
- Kyverno Documentation: https://kyverno.io/docs/
- Istio Ambient Waypoint PSS: https://github.com/istio/istio/issues
