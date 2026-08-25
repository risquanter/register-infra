# ADR-INFRA-017: Developer & CI Toolchain Management — mise

**Status:** Accepted
**Date:** 2026-08-24
**Tags:** supply-chain, toolchain, ci, dependencies, developer-experience

---

## Context

- The project depends on a set of host command-line tools — terraform, kubectl, helm, k3d, cilium-cli, istioctl, sops, age, age-plugin-yubikey, argocd, plus the test-suite tools conftest, opa, trivy, bats, and yq — on both the developer machine and the CI runner. Nothing currently pins them as a set. Several are installed ad-hoc against mutable references (`curl .../main/install.sh | bash`, `.../releases/latest`), which ADR-INFRA-012 §3 prohibits: the version you get depends on the day you run the installer.
- The commands run against those tools (a bootstrap sequence, a `terraform plan`, an image build-and-push, a lint pass) exist twice: as prose in the docs for the local path, and as steps inside a GitHub Actions workflow for the CI path. Two definitions of the same command drift apart; nothing keeps them byte-identical.
- CI pins tool versions independently of the local environment. `hashicorp/setup-terraform` fixes `terraform_version` inside the workflow, unrelated to whatever terraform the developer has. A version match between local and CI is coincidental, not enforced.
- ADR-INFRA-012 already governs *what* an external artifact must satisfy — vendor identity (§2), immutable pinning (§3), cooldown (§4), approval record (§6) — across all four blast-radius tiers, including T3 (CI/build-time) and T4 (dev machine). What it does not specify is the *mechanism* that installs and pins host CLI tools, nor the convention for how CI consumes them. This ADR fills that gap; it does not restate 012's rules.

---

## Decision

### 1. mise is the toolchain and task-runner mechanism

A single `mise.toml` at the repository root is the one place that both pins every host/CI CLI tool to an exact version and defines the task commands run against them. mise (a single binary; reads `mise.toml`) installs the pinned tools on demand (`mise install`) and runs the defined tasks (`mise run <task>`). One file closes both version drift and command drift.

The developer installs mise once from its vendor's official release. CI installs mise via the `jdx/mise-action` GitHub Action (§4). Everything downstream — which terraform, which helm, what `tf:plan` actually runs — comes from the committed `mise.toml`, identically in both places.

### 2. Vendor-identity-correct backends (defers to ADR-INFRA-012 §2)

A mise *backend* is the resolver that fetches a tool's binary. Each tool is configured with a backend that fetches the **vendor's own release artifact** — the `core` backend (mise-maintained, points at the vendor's official distribution), `aqua:` (aqua registry, which maps to official GitHub releases with published checksums), or `ubi:` (fetches directly from a named GitHub owner/repo's release assets). The community asdf plugin registry and any aggregator or mirror are rejected, exactly as ADR-INFRA-012 §2 requires for every tier. The chosen backend for each tool is recorded in the `mise.toml` approval record so a reader can confirm the resolution path is the vendor's.

### 3. Pinning, tiering, and cooldown defer to ADR-INFRA-012

This ADR adds no new supply-chain rules. The tools in `mise.toml` are pinned and governed entirely under ADR-INFRA-012:

- **Pinning** — exact version per tool (ADR-INFRA-012 §3, host/CI CLI binary row), with a committed `mise.lock` recording checksums where the backend supports it. No version ranges, no `latest`.
- **Tier** — terraform runs in CI at build time, so it is **T3**; every other CLI runs only on the developer machine and is **T4**. `jdx/mise-action` is a GitHub Action, **T3**, SHA-pinned per §3.
- **Cooldown** — applied at adoption and each bump from the tool's public release date (ADR-INFRA-012 §4: T3 new-adoption 14 days, T4 7 days).
- **Approval record** — each tool carries the ADR-INFRA-012 §6 comment block in `mise.toml` (vendor, backend, pinned version, cooldown-elapsed line, reviewed date). §6 is formally mandated only at T1/T2; recording it here for T3/T4 tools is the project convention so every pinned tool is auditable in-file.

### 4. CI is thin — it installs the toolchain and calls tasks

A CI workflow does not define tool versions or command strings. It checks out the repo, installs the pinned toolchain, and invokes a task:

```yaml
- uses: actions/checkout@<sha>       # v4.x
- uses: jdx/mise-action@<sha>        # v4.x — installs mise, then runs `mise install`
  with:
    version: <pinned mise version>   # exact tools resolved from mise.toml / mise.lock
- run: mise run tf:plan              # the same command a developer runs locally
```

The action installs mise (pinned by the `version` input) and, by default, runs
`mise install` to fetch the exact toolchain from `mise.toml` — so no separate
install step is needed. Per-tool setup actions (`hashicorp/setup-terraform` and
equivalents) are replaced by this pattern: the tool version lives in `mise.toml`,
not in a workflow input, so local and CI resolve to the same binary.
`jdx/mise-action` is SHA-pinned and carries its approval record like any other
GitHub Action.

### 5. Tasks are tool-agnostic shell

`[tasks]` in `mise.toml` hold portable shell commands. A task is the exact command the operational docs specify — the image-deploy loop (`image:build` / `image:push`, `deploy:refresh` / `deploy:rollout`), `tf:plan` / `tf:apply`, a format/validate pass (`tf:fmt` / `tf:validate`), the regression suite (`test`), a secrets check (`secrets:check`). The docs cite the task name; the command itself lives once, in `mise.toml`. A task defined for the CI path (the terraform tasks) runs byte-identically for the developer and CI; dev-machine-only tasks such as the image-deploy loop run against the developer's `../register` sibling checkout and are not invoked in CI.

---

## Code Smells

### ❌ Floating install of a host CLI

```bash
# BAD: mutable reference — the version depends on the day you run this.
curl -sfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
SOPS_VERSION=$(curl -s .../getsops/sops/releases/latest | jq -r .tag_name)
```

```toml
# GOOD: exact pin in mise.toml via a vendor-correct backend, with a §6 record.
[tools]
k3d = "5.7.4"
sops = "3.9.1"
```

### ❌ Tool version pinned inside a workflow, separate from local

```yaml
# BAD: CI's terraform is unrelated to the developer's; they drift.
- uses: hashicorp/setup-terraform@<sha>
  with:
    terraform_version: "1.15.8"
```

```yaml
# GOOD: one source of truth; the action installs exactly what mise.toml pins.
- uses: jdx/mise-action@<sha>
  with:
    version: <pinned mise version>
```

### ❌ Command defined twice (docs prose + workflow steps)

```yaml
# BAD: the plan command lives in the workflow AND in the docs — they diverge.
- run: terraform -chdir=infra/terraform/envs/hetzner plan -input=false -out=tfplan
```

```yaml
# GOOD: the command lives once as a task; docs and CI both call it.
- run: mise run tf:plan
```

---

## Implementation

| Location | Pattern |
|---|---|
| `mise.toml` | Exact version pins per tool via §2-correct backends; §6 approval records in-file; `[tasks]` command definitions |
| `mise.lock` | Committed checksum lock where the backend supports it |
| `.github/workflows/*.yaml` | Thin CI — `jdx/mise-action` (SHA-pinned) + `mise install` + `mise run <task>`; no per-tool setup actions, no inline versions |
| `docs/MANUAL-BOOTSTRAP.md`, `docs/START-HERE.md`, `docs/TERRAFORM-BOOTSTRAP.md` | Cite `mise run <task>` / the pinned toolchain instead of ad-hoc installs |

---

## Alternatives Rejected

### Makefile (or just) for tasks + asdf for versions

- **What**: A `Makefile`/`justfile` holds the task commands; asdf (reading `.tool-versions`) pins the tool versions — two files, two tools.
- **Why rejected**: Two mechanisms to install and keep coherent instead of one. asdf resolves tools through its community plugin registry, where the plugin author is frequently not the tool's vendor — a standing ADR-INFRA-012 §2 conflict that mise's `core`/`aqua:`/`ubi:` backends avoid by fetching the vendor's own release. mise reads `.tool-versions` too, so the asdf ecosystem is not lost by choosing mise.

### Per-workflow `setup-<tool>` actions

- **What**: Keep `hashicorp/setup-terraform` and add a `setup-<tool>` action per additional tool CI needs.
- **Why rejected**: Each action pins its tool's version inside the workflow, independent of the developer's environment, so local and CI drift. It also multiplies the T3 GitHub Actions to SHA-pin and record. `jdx/mise-action` installs the whole pinned set from the one committed manifest.

### Keep ad-hoc `curl | bash` installs, document versions in prose

- **What**: Leave the current installers; write the intended versions into the docs.
- **Why rejected**: A version in prose is not an enforced pin — the installer still fetches `main`/`latest`. This is the ADR-INFRA-012 §3 violation the decision exists to remove.

---

## References

- ADR-INFRA-012 — Supply Chain Defence (blast-radius tiers, vendor identity, pinning incl. the host/CI CLI binary row, cooldown, approval record). All pinning and tiering for the tools mise manages defers here.
- ADR-INFRA-016 — Helm Chart Sourcing (companion supply-chain ADR; charts, not CLIs)
- mise — https://mise.jdx.dev (tool-version manager, env manager, task runner)
- `jdx/mise-action` — https://github.com/jdx/mise-action (installs mise + pinned tools in CI)
