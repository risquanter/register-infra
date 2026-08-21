# ── Platform Helm layer — identical for every target ─────────────────────────
#
# The caller gates this whole module on cluster readiness with a module-level
# `depends_on` (see envs/local, envs/hetzner), so no resource here needs its own
# dependency on the cluster. The install order between the releases below is
# enforced by the depends_on chain: Cilium → Istio (base → cni → ztunnel →
# istiod) → cert-manager → ArgoCD → Image Updater.
#
# Component rationale (why Cilium replaces flannel, why the ambient order, the
# ArgoCD mesh-enrollment step) lives in docs/GITOPS-OPERATIONS.md.

# ── Cilium — CNI ──────────────────────────────────────────────────────────────

# cni.exclusive = false is mandatory: Istio ambient installs its own CNI plugin
# (istio-cni) alongside Cilium. Cilium must not claim sole CNI ownership.
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  set {
    name  = "cni.exclusive"
    value = "false"
  }

  set {
    name  = "operator.replicas"
    value = "1" # single-node — one replica sufficient
  }
}

# ── Istio ambient — service mesh ──────────────────────────────────────────────

# Installation order: base → cni → ztunnel → istiod. Each release depends on the
# previous via depends_on; out-of-order installation causes CRD-not-found errors.
# profile = "ambient" selects sidecar-less mode — ztunnel carries L4 mTLS and
# waypoints carry L7 policy, instead of an Envoy sidecar in every pod.

resource "helm_release" "istio_base" {
  depends_on       = [helm_release.cilium]
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = "istio-system"
  create_namespace = true
}

resource "helm_release" "istio_cni" {
  depends_on = [helm_release.istio_base]
  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = var.istio_version
  namespace  = "istio-system"

  set {
    name  = "profile"
    value = "ambient"
  }
}

resource "helm_release" "ztunnel" {
  depends_on = [helm_release.istio_cni]
  name       = "ztunnel"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "ztunnel"
  version    = var.istio_version
  namespace  = "istio-system"
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.ztunnel]
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = "istio-system"

  set {
    name  = "profile"
    value = "ambient"
  }
}

# ── cert-manager — TLS certificate lifecycle ──────────────────────────────────

resource "helm_release" "cert_manager" {
  depends_on       = [helm_release.istiod]
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  # Install cert-manager's CRDs (Certificate, ClusterIssuer, …) with the chart;
  # otherwise the chart's controllers reference types that do not yet exist.
  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# ── ArgoCD — GitOps controller ────────────────────────────────────────────────

# After ArgoCD is running, all further cluster state is declared in git and
# applied by ArgoCD — Terraform does not manage application-level resources.
#
# server.insecure = true: ArgoCD's own TLS listener is disabled. Ztunnel
# provides mTLS between ArgoCD pods once the namespace is enrolled in the
# mesh (a required post-bootstrap step — see docs/GITOPS-OPERATIONS.md). Access
# from the operator is via kubectl port-forward, which uses the k8s API server's
# own TLS.
#
# IMPORTANT: helm install creates the argocd namespace WITHOUT the Istio
# ambient label. Two-part fix:
#   1. Post-bootstrap: kubectl label namespace argocd istio.io/dataplane-mode=ambient
#      (closes the ~60s window before ArgoCD syncs the namespace chart)
#   2. infra/helm/namespaces/values.yaml declares argocd with meshEnroll: true
#      (ArgoCD self-heal maintains the label — drift-proof under GitOps)
resource "helm_release" "argocd" {
  depends_on       = [helm_release.cert_manager]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}

# ── ArgoCD Image Updater ──────────────────────────────────────────────────────

# Image Updater polls GHCR for new image digests and commits the updated tag
# back to git. ArgoCD then detects the commit and syncs the cluster. It is only
# active on GHCR image-repo points — a local-registry point leaves it idle.
resource "helm_release" "argocd_image_updater" {
  depends_on = [helm_release.argocd]
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = var.argocd_image_updater_version
  namespace  = "argocd"

  set {
    name  = "config.argocd.insecure"
    value = "true"
  }
}
