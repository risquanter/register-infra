# ADR-INFRA-007: SPA Serving Strategy — nginx Frontend Pod + Istio Gateway Ingress

**Status:** Accepted (frontend chart at `infra/helm/frontend/`; Istio Gateway ingress implemented, HTTPS/443 — see ADR-INFRA-013 for the ingress datapath. Hetzner needs only the ACME issuer swap.)  
**Date:** 2026-03-10  
**Tags:** frontend, spa, nginx, istio-gateway, ingress, routing

---

## Context

- A browser navigating to `/w/{key}` (bookmark, refresh, shared link) sends `GET /w/{key}` with `Accept: text/html` — the server must return `index.html`; without server-side handling this is a 404
- The same `/w/{key}` path is a live API endpoint; the proxy must distinguish browser navigation from API calls using the `Accept` header (`text/html` → SPA shell, `application/json` → backend)
- Istio is a proxy, not a file server — it can route between backends but cannot serve files from a filesystem; `try_files`-style fallback to `index.html` requires a file-serving component
- TLS termination and SPA file serving are separate concerns; separating them keeps each component replaceable independently
- `/w/*` paths use capability-URL authorization (ADR-021): the URL is the credential, no JWT is present; the Istio `RequestAuthentication` / `AuthorizationPolicy` must exempt these paths from the JWT requirement

---

## Decision

### 1. nginx Pod as File Server and Accept-Header Router

An nginx `Deployment` in the `register` namespace serves static SPA assets and applies Accept-header discrimination for the `/w/*` path. All routing logic lives in nginx config, not in Istio/Gateway API resources.

```nginx
# Key routing rule — dual-purpose /w/* path
location /w/ {
    # JSON API calls (Fetch/XHR from SPA JavaScript)
    if ($http_accept ~* "application/json") {
        proxy_pass http://register.register.svc.cluster.local:8090;
        break;
    }
    # Browser navigation → SPA shell
    try_files $uri /index.html;
}

# Static assets — longest-match wins over SPA fallback
location ~* \.(js|css|woff2|svg|png|ico)$ {
    root /srv/app;
    expires 1y;
    add_header Cache-Control "public, immutable";
}

# API endpoints — unconditionally proxied
location /workspaces { proxy_pass http://register.register.svc.cluster.local:8090; }
location /health     { proxy_pass http://register.register.svc.cluster.local:8090; }
location /docs       { proxy_pass http://register.register.svc.cluster.local:8090; }

# Default — SPA fallback
location / {
    root /srv/app;
    try_files $uri /index.html;
}
```

### 2. Istio Gateway for TLS Termination Only

An Istio `Gateway` resource (separate from the namespace waypoint) listens on port 443, terminates TLS using a cert-manager `Certificate`, and forwards all traffic to the nginx `Service` without any path or header matching. The `HTTPRoute` is simple: one rule, one backend.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: register-ingress
  namespace: register
spec:
  gatewayClassName: istio
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: register-tls   # cert-manager Certificate
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: register-ingress
  namespace: register
spec:
  parentRefs:
    - name: register-ingress
  rules:
    - backendRefs:
        - name: frontend
          port: 80
```

### 3. AuthorizationPolicy Exception for Capability URLs

`/w/*` paths use capability-URL authorization (ADR-021) — the URL is the credential, no JWT is present. An `AuthorizationPolicy` ALLOW rule must exempt these paths from the JWT requirement enforced on all other routes.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-capability-urls
  namespace: register
spec:
  action: ALLOW
  rules:
    - to:
        - operation:
            paths: ["/w/*"]
```

### 4. Container Image Lives in the register Repo

The frontend image is a multi-stage build: Node build stage produces `index.html` and static assets; the runtime stage copies them into an nginx base image alongside a baked-in `nginx.conf`.

It belongs in the `risquanter/register` repo at `containers/prod/Dockerfile.frontend-prod`, following the established layout:

```
containers/
  builders/   Dockerfile.irmin-builder, Dockerfile.graalvm-builder
  dev/        Dockerfile.irmin-dev, Dockerfile.register-dev
  prod/       Dockerfile.irmin-prod, Dockerfile.register-prod
              Dockerfile.frontend-prod   ← new
```

`register-infra` does not build images. It only references them by tag in Helm values, identical to how it references the register-server and irmin images.

---

## Code Smells

### ❌ Accept-Header Routing in HTTPRoute

```yaml
# BAD: attempting Accept-header split at the Istio layer.
# HTTPRoute can match headers and route to backends, but it cannot serve
# files. There is no backend to route text/html requests to — index.html
# lives on disk, not in a Service.
rules:
  - matches:
      - headers:
          - name: Accept
            value: application/json
    backendRefs:
      - name: register
        port: 8090
  - backendRefs:
      - name: ??? # no file server exists here
```

```nginx
# GOOD: the entire routing decision is in nginx where a file system is available.
```

### ❌ TLS Termination in nginx, Bypassing the Istio Gateway

```yaml
# BAD: mounting the cert-manager certificate directly into nginx.
# This bypasses TLS lifecycle management, duplicates certificate wiring,
# and removes the ability to enforce mTLS between the gateway and the pod.
volumes:
  - name: tls
    secret:
      secretName: register-tls
containers:
  - name: frontend
    volumeMounts:
      - name: tls
        mountPath: /etc/nginx/ssl
```

```yaml
# GOOD: Istio Gateway terminates TLS; nginx receives plaintext internally.
# cert-manager renews the certificate; the Gateway picks up the rotation.
```

### ❌ nginx Config as Inline Values String

```yaml
# BAD: embedding nginx.conf as a raw string in Helm values.yaml.
# No syntax highlighting, no validation, no reuse across environments.
nginxConf: |
  server { location / { ... } }
```

```yaml
# GOOD: nginx.conf in a dedicated ConfigMap template with named fields
# or — preferably — baked into the container image (no runtime ConfigMap dependency).
```

---

## Implementation

| Location | Artifact |
|----------|---------|
| `risquanter/register` → `containers/prod/Dockerfile.frontend-prod` | Multi-stage image: Node build + nginx runtime + nginx.conf |
| `infra/helm/frontend/` | Helm chart: Deployment, Service, ServiceAccount, NetworkPolicy |
| `infra/argocd/apps/frontend.yaml` | ArgoCD Application for the frontend chart |
| `infra/k8s/istio/` | `Gateway` + `HTTPRoute` resources; `AuthorizationPolicy` for `/w/*` |
| `infra/secrets/` | cert-manager `ClusterIssuer` + `Certificate` for the domain |

---

## Alternatives Rejected

### CDN as Primary Serving Mechanism

- **What**: push built SPA assets (JS, CSS, HTML) to a CDN edge network (Cloudflare, CloudFront); use edge functions for Accept-header routing; point the CDN origin to the Hetzner node for API calls
- **Why rejected**: CDNs add value for geographic distribution and DDoS protection — neither is relevant at the current scale and user base. The architecture is equivalent (static file server + API proxy), just relocated to the edge; the switch is not architecturally disruptive and is identified as a potential improvement should geographic reach or traffic volume warrant it in the future. Starting with an nginx pod avoids premature dependency on a third-party network service while the application is not yet in production.

### Dedicated Ingress Controller (Traefik, nginx-ingress)

- **What**: install a full Ingress controller (Traefik or nginx-ingress) as the cluster entry point; use `Ingress` resources for routing
- **Why rejected**: Gateway API (already supported by Istio ambient) replaces the `Ingress` API for new deployments. Adding a dedicated ingress controller introduces a third L7 proxy alongside Istio's waypoint and the frontend nginx pod, with no capability benefit. k3s Traefik is already explicitly disabled in cluster config.

### Istio Gateway + Separate nginx-as-Sidecar

- **What**: run nginx as a sidecar in the register application pod to handle SPA fallback; no dedicated frontend pod
- **Why rejected**: sidecars conflict with Istio ambient mode (which is sidecar-free by design). A dedicated frontend `Deployment` is the correct ambient-mode pattern for a separate serving component.

---

## References

- ADR-021: Capability URLs — authorization model for `/w/*` paths (no JWT, URL is the credential)
- ADR-025 (register repo): SPA Routing Strategy — choice of path-based over hash-based routing and the resulting proxy requirement
- [Istio Gateway API documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
