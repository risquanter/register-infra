# GitOps Operations Reference

Shared operational reference for the register-infra platform. This document
covers everything managed by ArgoCD after bootstrap completes — it is the
same regardless of whether your cluster is a local k3d instance or a Hetzner
Cloud VM.

- **Bootstrap guides** create the cluster and platform layer:
  [LOCAL-K3D-BOOTSTRAP.md](LOCAL-K3D-BOOTSTRAP.md) (local dev) or
  [K3S-GITOPS-BOOTSTRAP.md](K3S-GITOPS-BOOTSTRAP.md) (Hetzner production)
- **This document** explains what ArgoCD manages, how to make changes, and
  how to troubleshoot the GitOps layer
- **Testing** is covered in [K8S-TESTING.md](K8S-TESTING.md)
- **Security architecture** is diagrammed in [SECURITY-FLOW.md](SECURITY-FLOW.md)

---

## Repository layout

> **Why this layout?** ArgoCD watches specific paths in the repo. Organizing
> by tool (Terraform, Helm, ArgoCD apps, raw k8s manifests) keeps concerns
> separated and makes ArgoCD path filters work cleanly.

```
infra/
  terraform/                    # VM provisioning + bootstrap Helm releases
    main.tf                     #   all Terraform resources (network, firewall, VM, Helm)
    variables.tf                #   input variables with defaults
    outputs.tf                  #   output values (server IP etc.)
    cloud-init.yaml             #   first-boot script: installs k3s
  helm/
    register/                   # application Helm chart
      Chart.yaml
      values.yaml
      templates/
        _helpers.tpl
        deployment.yaml
        service.yaml
        serviceaccount.yaml
    namespaces/                 # namespace declarations with PSS + mesh + LimitRange
      Chart.yaml
      values.yaml
      values-infra-no-mesh.yaml #   fallback: removes infra from mesh
      templates/
        namespaces.yaml
        limitrange.yaml
    opa/                        # OPA ext_authz Helm chart
      Chart.yaml
      values.yaml
      policies/
        allow.rego              #   canonical Rego source (single-source-of-truth)
      templates/
        _helpers.tpl
        configmap.yaml          #   Files.Get from policies/allow.rego
        deployment.yaml
        service.yaml
        pdb.yaml
  argocd/
    apps/                       # App of Apps directory — ArgoCD watches this
      root.yaml                 #   the single root Application
      namespaces.yaml           #   namespace chart
      postgresql.yaml           #   PostgreSQL (Bitnami remote chart)
      keycloak.yaml             #   Keycloak (Bitnami remote chart)
      register.yaml             #   application Deployment + Image Updater
      opa.yaml                  #   OPA Helm chart
      mesh-policy.yaml          #   Istio/OPA/NetworkPolicy/RBAC manifests
    projects/                   # AppProject definitions — least-privilege scoping
      platform.yaml             #   namespaces, mesh, OPA, RBAC, NetworkPolicy
      infra.yaml                #   PostgreSQL, Keycloak
      app.yaml                  #   register application
  k8s/
    istio/                      # Istio L7 security policies
      request-authentication.yaml
      authorization-policy.yaml
      peer-authentication.yaml
      envoy-filter-strip-headers.yaml
    network-policy/             # Cilium NetworkPolicies (default-deny + allow rules)
      register.yaml
      infra.yaml
    opa/                        # OPA ext_authz EnvoyFilter wiring
      ext-authz-filter.yaml
    rbac/                       # RBAC role definitions
      roles.yaml
  secrets/                      # SOPS-encrypted Secret manifests (committed safely)
docs/
  adr/                          # Architecture Decision Records
    ADR-00X.md                  #   template
    ADR-INFRA-001.md            #   Configuration single-source-of-truth
    ADR-INFRA-002.md            #   Fail-closed availability guarantees
    ADR-INFRA-003.md            #   AppProject scoping
    ADR-INFRA-004.md            #   Defence-in-depth layered controls
    ADR-INFRA-005.md            #   Testing strategy — tool selection and skip semantics
tests/
  run-regression.sh             # wrapper with strict skip semantics (ADR-INFRA-005)
  bats/
    header-security.bats        # identity header regression suite (bats-core)
  conftest/
    policy/                     # OPA/Rego static policies for conftest
      authorizationpolicy.rego
      envoyfilter.rego
      networkpolicy.rego
      peerauthentication.rego
      requestauthentication.rego
.sops.yaml                      # SOPS config (age recipient public key)
```

---

## What ArgoCD manages

### AppProject scoping

ArgoCD uses three scoped AppProjects to enforce least-privilege boundaries
(see [ADR-INFRA-003](adr/ADR-INFRA-003.md)):

| Project | Scope | Allowed namespaces | Can create cluster-scoped resources? |
|---|---|---|---|
| `platform` | Namespace provisioning, mesh policy, OPA, RBAC, NetworkPolicy | default, register, argocd, istio-system, infra | Yes — Namespace only |
| `infra` | Infrastructure services (PostgreSQL, Keycloak) | infra only | No |
| `app` | Application workloads (register) | register only | No |

The `root` Application remains in the `default` project because it must create
Application and AppProject resources in the `argocd` namespace.

### Application declarations (`infra/argocd/apps/`)

| File | What it declares | Project | Key configuration |
|---|---|---|---|
| [root.yaml](../infra/argocd/apps/root.yaml) | Root App of Apps | default | Watches `infra/argocd/apps/` + `infra/argocd/projects/` via `sources`, automated sync + prune + self-heal, cascade finalizer |
| [namespaces.yaml](../infra/argocd/apps/namespaces.yaml) | Namespace Helm chart | platform | Points at `infra/helm/namespaces/`, creates namespaces with PSS labels, mesh enrollment, and LimitRanges |
| [postgresql.yaml](../infra/argocd/apps/postgresql.yaml) | PostgreSQL database | infra | Bitnami chart v16.4.0, references `postgres-credentials` Secret, 10Gi PVC, hardened securityContext |
| [keycloak.yaml](../infra/argocd/apps/keycloak.yaml) | Keycloak IdP | infra | Bitnami chart, connects to PostgreSQL via internal DNS, references encrypted credentials |
| [register.yaml](../infra/argocd/apps/register.yaml) | Application Deployment | app | Image Updater annotations for automated GHCR → git → cluster deploy loop |
| [opa.yaml](../infra/argocd/apps/opa.yaml) | OPA Helm chart | platform | 2 replicas + PDB, policy from single canonical Rego source via `Files.Get` |
| [mesh-policy.yaml](../infra/argocd/apps/mesh-policy.yaml) | Security policies | platform | Istio JWT/auth, PeerAuthentication, OPA ext_authz EnvoyFilter, NetworkPolicies, RBAC role definitions |

### Namespace chart (`infra/helm/namespaces/`)

The namespace Helm chart at [infra/helm/namespaces/](../infra/helm/namespaces/)
declares each namespace with:

- **Pod Security Standards labels**: `enforce`, `audit`, `warn` — controls what
  pods are allowed to run (e.g. `restricted` prohibits root containers)
- **Mesh enrollment label**: `istio.io/dataplane-mode: ambient` — tells Istio's
  ztunnel to intercept traffic for this namespace
- **LimitRange** (optional): default resource requests/limits for pods that
  don't declare them — prevents unbounded resource consumption

See [values.yaml](../infra/helm/namespaces/values.yaml) for the namespace
definitions. A fallback file
[values-infra-no-mesh.yaml](../infra/helm/namespaces/values-infra-no-mesh.yaml)
removes the `infra` namespace from the mesh (useful if database pods have probe
issues with ztunnel — see [Troubleshooting](#postgresql-or-keycloak-crash-after-mesh-enrollment)).

> **TODO: ResourceQuota migration.** LimitRange sets *default* resource
> requests/limits for pods that don't declare them. It does **not** cap total
> namespace resource consumption. Once resource profiles are understood
> (`kubectl top pods -n register`), add per-namespace ResourceQuota to the
> namespaces chart (`templates/resourcequota.yaml`) with hard caps on CPU,
> memory, and pod count. This prevents a runaway pod from starving OPA —
> which with `failure_mode_deny: true` would cause 100% 403 for all requests.

### OPA chart (`infra/helm/opa/`)

The OPA Helm chart at [infra/helm/opa/](../infra/helm/opa/) deploys the
Open Policy Agent with the `envoy_ext_authz_grpc` plugin. Key design decisions:

- **2 replicas + PodDisruptionBudget** (minAvailable: 1) — OPA runs with
  `failure_mode_deny: true`, so unavailability = 100% 403 for all requests
  (see [ADR-INFRA-002](adr/ADR-INFRA-002.md))
- **Policy loaded via `Files.Get`** — the ConfigMap template reads
  `policies/allow.rego` directly, eliminating copy drift between the canonical
  Rego source and the deployed policy (see [ADR-INFRA-001](adr/ADR-INFRA-001.md))
- **Restricted security context** — `runAsNonRoot`, `readOnlyRootFilesystem`,
  `capabilities: drop ALL`, `automountServiceAccountToken: false`

### Security policies (`infra/k8s/`)

| File | What it enforces |
|---|---|
| [istio/request-authentication.yaml](../infra/k8s/istio/request-authentication.yaml) | Validates JWT signatures against Keycloak's JWKS endpoint; `outputClaimToHeaders` injects `x-user-id`, `x-user-email`, `x-user-roles`; audience validation (`register-api`) prevents token confusion |
| [istio/authorization-policy.yaml](../infra/k8s/istio/authorization-policy.yaml) | Requires valid JWT on authenticated routes; exempts public routes (`/w/*`, `/workspaces/*`, `/health`) |
| [istio/envoy-filter-strip-headers.yaml](../infra/k8s/istio/envoy-filter-strip-headers.yaml) | Strips forged identity headers (`x-user-id`, `x-user-email`, `x-user-roles`) before JWT validation |
| [istio/peer-authentication.yaml](../infra/k8s/istio/peer-authentication.yaml) | STRICT mTLS for `register` and `argocd` namespaces (per-namespace; mesh-wide deferred — see TODO in file) |
| [opa/ext-authz-filter.yaml](../infra/k8s/opa/ext-authz-filter.yaml) | Routes waypoint authorization checks to OPA gRPC (port 9191, 100ms timeout, fail-closed) |
| [network-policy/register.yaml](../infra/k8s/network-policy/register.yaml) | Default-deny + targeted allows: waypoint→app, waypoint→OPA, app→PostgreSQL, app→Keycloak, DNS egress |
| [network-policy/infra.yaml](../infra/k8s/network-policy/infra.yaml) | Default-deny + targeted allows: register→PostgreSQL, register→Keycloak, Keycloak→PostgreSQL, ArgoCD health checks, istiod→Keycloak JWKS, DNS egress |
| [rbac/roles.yaml](../infra/k8s/rbac/roles.yaml) | Role definitions: `viewer` (read-only), `deployer` (ops), `ci-authz` (SpiceDB provisioning). Not yet bound — see file comments |

---

## The automated deploy loop

> **This is the end-state workflow** — how application code changes reach the
> running cluster without any manual intervention.

```
git push (application code change)
  → GitHub Actions (CI):
      - sbt test (compile + unit tests)
      - docker buildx build --push ghcr.io/<org>/<image>:<git-sha>
  → ArgoCD Image Updater (runs in-cluster, polls GHCR every ~2 min):
      - detects new image digest at ghcr.io/<org>/<image>
      - commits updated tag to infra/helm/register/.argocd-source-register.yaml
  → ArgoCD (polls git every ~3 min, or via webhook for instant sync):
      - detects the commit on HEAD
      - renders Helm chart with new image tag
      - performs rolling update in the register namespace
  → new pod running within ~90 seconds of git push
```

> **Webhook for instant sync**: for faster feedback, configure a GitHub webhook
> pointing at the ArgoCD API server. This requires the ArgoCD server to be
> reachable from the internet (via an Ingress or Cloudflare Tunnel).

For **infrastructure changes** (policies, Helm values, new ArgoCD apps),
the loop is simpler:

```
git push (infra repo change)
  → ArgoCD detects changed files (polls git every ~3 min)
  → ArgoCD re-renders affected Helm charts or re-applies raw manifests
  → cluster state converges to match git
```

---

## Making changes — the GitOps workflow

> **This is how you work day-to-day.** After bootstrap, every change to the
> cluster is made by editing files in this repository and pushing to git.
> ArgoCD applies any changes within ~3 minutes (or instantly with webhooks).
>
> **GitOps best practices:**
> - **Never `kubectl apply` or `helm install` manually** for GitOps-managed
>   resources. ArgoCD will detect the "drift" (cluster differs from git) and
>   revert your change.
> - **Use branches and PRs** for changes. This gives you review, CI checks
>   (see [K8S-TESTING.md](K8S-TESTING.md)), and a git-based audit trail.
> - **Commit small, focused changes**. One policy change per commit, not a
>   bundle of unrelated edits. This makes rollback easier (`git revert`).
> - **Enable branch protection** on `main`: require PR reviews, require CI
>   to pass. This prevents accidental pushes to the branch ArgoCD watches.

### Example: edit an Istio policy

```bash
$EDITOR infra/k8s/istio/authorization-policy.yaml

git add infra/k8s/istio/authorization-policy.yaml
git commit -m "security: tighten authorization policy"
git push

# ArgoCD detects the change within ~3 minutes.
# Watch in the UI or via CLI:
argocd app get mesh-policy
```

### Example: change an application Helm value

```bash
$EDITOR infra/helm/register/values.yaml

git add infra/helm/register/values.yaml
git commit -m "feat: increase replica count"
git push

argocd app get register
```

### Example: preview what ArgoCD would change (dry-run)

```bash
# WHAT: "argocd app diff" compares the local files to what is deployed in the
# cluster. The output is like "git diff" but for Kubernetes resources.
# This is the GitOps equivalent of "terraform plan".
argocd app diff register --local infra/helm/register/
argocd app diff mesh-policy --local infra/k8s/
```

### Example: add a new service to the cluster

```bash
# 1. Create a Helm chart (or use an Application pointing at a remote chart)
mkdir -p infra/helm/new-service/templates
# ... write Chart.yaml, values.yaml, templates/

# 2. Create an ArgoCD Application file
cat > infra/argocd/apps/new-service.yaml <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: new-service
  namespace: argocd
spec:
  project: app   # or platform/infra depending on scope
  source:
    repoURL: https://github.com/<org>/register-infra
    targetRevision: HEAD
    path: infra/helm/new-service
  destination:
    server: https://kubernetes.default.svc
    namespace: register
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

# 3. Commit and push — ArgoCD discovers the new Application automatically
git add infra/helm/new-service/ infra/argocd/apps/new-service.yaml
git commit -m "feat: add new-service to GitOps"
git push
```

---

## Troubleshooting

### ArgoCD Application stuck at OutOfSync

```bash
# Port-forward to ArgoCD (adjust port to match your bootstrap guide)
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

# Force a sync and check for errors
argocd app sync <app-name>
argocd app get <app-name>

# Check events in the target namespace for details
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20

kill $PF_PID 2>/dev/null || true
```

### PostgreSQL or Keycloak crash after mesh enrollment

> **Known technical limitation.** The `infra` namespace is enrolled in the
> mesh (`meshEnroll: true` in `infra/helm/namespaces/values.yaml`). Ztunnel
> intercepts all L4 traffic, including kubelet liveness probes. PostgreSQL
> uses a custom binary wire protocol (not HTTP). When the kubelet probes
> port 5432 through ztunnel's HBONE tunnel, some PostgreSQL images fail the
> health check because the probe traffic arrives wrapped in a way the server
> doesn't expect.
>
> **This is a ztunnel/non-HTTP-protocol limitation, not a design choice.**
> Diagnose, mitigate, and if necessary fall back — but track it as a gap.

```bash
# DIAGNOSE: check what actually failed.
kubectl -n infra get events --sort-by=.lastTimestamp | tail -20
kubectl -n infra describe pod <postgres-pod>
# Look for: "Liveness probe failed" or "connection refused" on probe ports.

# MITIGATION 1: exclude probe ports from ztunnel interception.
# Edit infra/helm/namespaces/values.yaml — uncomment probeExcludePorts.
# Then apply the annotation to the StatefulSet:
kubectl -n infra patch statefulset register-postgres-postgresql \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/annotations","value":{"traffic.sidecar.istio.io/excludeInboundPorts":"5432"}}]'

# MITIGATION 2 (full rollback): remove the infra namespace from the mesh.
# This means app→postgres and app→keycloak traffic becomes plaintext TCP.
# State this clearly as an accepted risk — the reason is a technical
# limitation in ztunnel's non-HTTP protocol handling, not because infra
# "doesn't need encryption".
kubectl label namespace infra istio.io/dataplane-mode- --overwrite
# Or use the dedicated rollback values file:
# helm upgrade namespaces ./infra/helm/namespaces \
#   -f infra/helm/namespaces/values.yaml \
#   -f infra/helm/namespaces/values-infra-no-mesh.yaml
```

### Quick health check

```bash
kubectl get nodes
kubectl get ns --show-labels
kubectl -n kube-system get pods         # Cilium
kubectl -n istio-system get pods        # Istio (istiod, ztunnel, istio-cni)
kubectl -n cert-manager get pods        # cert-manager
kubectl -n argocd get pods              # ArgoCD + Image Updater
kubectl -n infra get pods               # PostgreSQL, Keycloak
kubectl -n register get pods            # application + OPA
kubectl -n register get gateway         # waypoint proxy
```

---

## Glossary

A reference for terms used across the register-infra documentation. Skim
before starting a bootstrap guide; revisit as needed.

### Core Kubernetes concepts

| Term | Definition |
|---|---|
| **Cluster** | A set of machines (nodes) running Kubernetes. In k3d, the cluster is Docker containers on your machine; on Hetzner, it is a VM. |
| **Node** | A single machine in a cluster. Runs pods. |
| **Pod** | The smallest deployable unit — one or more containers that share networking and storage. Most pods have one container. |
| **Container** | A lightweight, isolated process running from a Docker/OCI image. |
| **Namespace** | A logical partition inside a cluster. Pods in different namespaces are isolated by default. |
| **Deployment** | Declares "run N copies of this pod". Kubernetes ensures the actual count matches the declared count. |
| **StatefulSet** | Like a Deployment, but for databases: pods get stable names and persistent storage. PostgreSQL and Keycloak use this. |
| **DaemonSet** | Runs one copy of a pod on every node. Used by Cilium and Istio's ztunnel. |
| **Service** | A stable DNS name + IP that routes traffic to pods. Pods come and go; Services provide a stable address. |
| **Secret** | A Kubernetes resource for sensitive data (passwords, tokens). Optionally encrypted at rest with `--secrets-encryption` (enabled on Hetzner; not available in k3d). |
| **ConfigMap** | Like a Secret, but for non-sensitive configuration. |
| **CRD** | Custom Resource Definition — extends the Kubernetes API with new resource types (e.g. `Gateway`, `Certificate`). |
| **kubeconfig** | A file that tells kubectl how to connect to a cluster (server address, credentials). k3d creates this automatically; Terraform retrieves it from the VM. Never commit to git. |
| **RBAC** | Role-Based Access Control — Kubernetes' permission system. Who can do what, in which namespace. |
| **PVC** | Persistent Volume Claim — request for disk storage that survives pod restarts. Used by PostgreSQL. |

### Networking and security

| Term | Definition |
|---|---|
| **CNI** | Container Network Interface — the plugin providing pod networking. Without it, pods cannot communicate. Cilium is our CNI. |
| **eBPF** | Extended Berkeley Packet Filter — a Linux kernel technology Cilium uses for high-performance NetworkPolicy enforcement. |
| **NetworkPolicy** | Firewall rules between pods. "Default deny" means all traffic is blocked unless explicitly allowed. |
| **Service mesh** | Infrastructure layer managing service-to-service traffic. Provides mTLS, L7 policy, observability. Istio is our mesh. |
| **mTLS** | Mutual TLS — both sides of a connection present certificates and encrypt traffic. Istio does this automatically. |
| **ztunnel** | Istio ambient mode's L4 proxy. DaemonSet on every node. Encrypts all traffic between enrolled pods. Transparent — no sidecar. |
| **Waypoint proxy** | Istio ambient mode's L7 proxy. Per-namespace Envoy instance for JWT validation and authorization policies. |
| **Envoy** | High-performance proxy used by Istio. Handles connections, load balancing, policy enforcement. |
| **EnvoyFilter** | Istio CRD for low-level Envoy configuration. Used here to strip forged identity headers. |
| **Pod Security Standards (PSS)** | Kubernetes-native security profiles: `privileged` (no restrictions), `baseline` (prevents known exploits), `restricted` (maximum hardening). |
| **SPIFFE** | Identity standard for mTLS certificates. Each pod gets a unique cryptographic identity (SPIFFE ID). |

### Authentication

| Term | Definition |
|---|---|
| **JWT** | JSON Web Token — a signed JSON object with claims (user ID, email, roles, expiry). The mesh validates the signature. |
| **JWKS** | JSON Web Key Set — public keys Keycloak publishes. Istio caches them and verifies JWT signatures without per-request Keycloak calls. |
| **OIDC** | OpenID Connect — authentication protocol built on OAuth2. Keycloak implements OIDC. |
| **PKCE** | Proof Key for Code Exchange — OAuth2 extension preventing authorization code interception. Used for browser-based login. |
| **Realm** | Keycloak concept — an isolated tenant with its own users, roles, and clients. |
| **OPA** | Open Policy Agent — general-purpose policy engine. Evaluates Rego rules for role-based gating. |
| **Rego** | Policy language for OPA. Declarative rules like "allow if user has editor role". |

### GitOps and infrastructure

| Term | Definition |
|---|---|
| **GitOps** | Operations model where git is the single source of truth. Changes are made by pushing to git; a controller applies them. |
| **IaC** | Infrastructure as Code — managing infrastructure via code files instead of manual commands. |
| **Terraform** | IaC tool. Declares cloud resources (VMs, networks, firewalls). `terraform apply` creates them. Used in the Hetzner bootstrap. |
| **Terraform state** | File tracking what Terraform has created. Required for updates and teardown. Loss requires manual cleanup. |
| **cloud-init** | First-boot automation for VMs. Runs commands, writes files, installs packages on first start. |
| **App of Apps** | ArgoCD pattern: one root Application points to a directory of child Application files. Adding a service = adding a file. |
| **Reconciliation** | ArgoCD comparing git (desired) to cluster (actual) and applying differences. Runs every ~3 minutes. |
| **Self-healing** | ArgoCD reverting manual cluster changes to match git. Prevents configuration drift. |
| **Drift** | When cluster state diverges from git. ArgoCD detects and corrects drift automatically. |
| **Helm chart** | Package of Kubernetes YAML templates + values. Like apt packages, but for Kubernetes. |
| **SOPS** | Secrets OPerationS — encrypts/decrypts secret files. Values encrypted, keys visible for auditability. Used in production; local dev uses manual `kubectl create secret`. |
| **age** | Modern encryption tool. SOPS uses age keypairs for encrypting secret files (replaces GPG). |
| **GHCR** | GitHub Container Registry — hosts Docker images. Image Updater polls it for new versions. |

---

## Tooling overview

### Tools on your workstation

| Tool | What it does | Local dev | Hetzner production |
|---|---|---|---|
| **kubectl** | Kubernetes CLI — talks to the cluster API | All sections | All sections |
| **Helm** | Kubernetes package manager — installs charts | Bootstrap only | Via Terraform |
| **ArgoCD CLI** | Bootstrap-time ArgoCD management (login, repo add) | Bootstrap only | Bootstrap only |
| **Docker** | Container runtime — k3d runs k3s in Docker | Required | Not needed |
| **k3d** | Creates k3s clusters inside Docker containers | §1 (local) | Not needed |
| **Cilium CLI** | Installs and manages Cilium (CNI) | §2 (local) | Via Terraform |
| **istioctl** | Installs and manages Istio (service mesh) + waypoint | §3, §9 (local) | Via Terraform + §waypoint |
| **Terraform** | Provisions cloud infrastructure declaratively | Not needed | §3 (Hetzner) |
| **hcloud** | Hetzner Cloud CLI — API token and SSH key management | Not needed | §2 (Hetzner) |
| **age** | Generates encryption keypairs for SOPS | Not needed | §1 (Hetzner) |
| **SOPS** | Encrypts/decrypts secret files in git | Not needed | §1 (Hetzner) |
| **curl / jq** | HTTP requests and JSON parsing for testing | Testing | Testing |

### Running in-cluster (deployed by bootstrap or ArgoCD)

| Component | What it does | Who deploys it |
|---|---|---|
| **k3s** | Lightweight Kubernetes distribution | cloud-init (Hetzner) / k3d (local) |
| **Cilium** | CNI — pod networking + NetworkPolicy enforcement | Terraform Helm / Cilium CLI |
| **Istio** (istiod, ztunnel, istio-cni) | Service mesh — mTLS + L7 policy + waypoint proxies | Terraform Helm / istioctl |
| **cert-manager** | TLS certificate automation | Terraform Helm / Helm CLI |
| **ArgoCD** | GitOps controller — syncs cluster state to git | Terraform Helm / Helm CLI |
| **Image Updater** | Polls GHCR for new images, commits tag to git | Terraform Helm / Helm CLI |
| **OPA** | Policy engine — role-based gating via Rego rules | ArgoCD (opa.yaml) |
| **PostgreSQL** | Database for Keycloak + application | ArgoCD (postgresql.yaml) |
| **Keycloak** | Identity provider — issues JWTs, JWKS endpoint | ArgoCD (keycloak.yaml) |
