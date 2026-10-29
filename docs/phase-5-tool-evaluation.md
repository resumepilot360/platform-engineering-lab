# Phase 5 — DevSecOps tool evaluation

Date: 2026-10-29 · Status: **proposal, awaiting approval** (nothing installed yet)

## Constraints observed
- Cluster memory in use: ~4.4 GiB of 15 GiB (Docker Desktop). Phase 7 observability needs ~3 GiB, so Phase 5 should stay within **~1 GiB** of in-cluster footprint.
- Kernel `6.10.14-linuxkit` with BTF (`/sys/kernel/btf/vmlinux`), which meets the requirements of Falco's `modern_ebpf` driver (≥ 5.8 + BTF). No kernel module or headers needed.
- Built-in `ValidatingAdmissionPolicy` (CEL) is available in K3s v1.35.
- Already running in CI: **Semgrep** (SAST), **govulncheck** (Go dependencies and stdlib), **Trivy** (image vulnerabilities, two architectures).
- Already enforced in app namespaces by **Pod Security Admission `restricted`**: privileged, root, host network/PID/IPC, hostPath, capabilities, seccomp.

## Capability → candidate tools

| Capability | Candidates | Recommendation | Footprint |
|---|---|---|---|
| SAST | **Semgrep** ✓, CodeQL, gosec | Keep Semgrep (CodeQL is free on public repos but slower and duplicates coverage) | CI only |
| Dependency scanning | **govulncheck** ✓, Trivy fs, Dependabot | Keep govulncheck (call-graph aware: reports only reachable vulns). Add **Dependabot** for Actions and Docker base-image bumps | CI / GitHub |
| Container scanning | **Trivy** ✓, Grype | Keep Trivy | CI only |
| K8s manifest scanning | **Trivy config**, Checkov, kube-linter, kubeconform ✓ (schema only) | **Trivy config** on rendered Kustomize output. Same tool as image scanning, built-in Kubernetes misconfiguration rules | CI only |
| SBOM | **Syft**, Trivy SBOM, BuildKit `sbom: true` | **Syft** (CycloneDX + SPDX), attached to each image as a **signed attestation** | CI only |
| Image signing | **Cosign keyless**, Cosign with key, Notation | **Cosign keyless**: GitHub OIDC identity → Fulcio short-lived cert → Rekor transparency log. No long-lived signing key to protect | CI only |
| Admission policy | **Kyverno**, ValidatingAdmissionPolicy (VAP), Gatekeeper, sigstore policy-controller | **Kyverno** (below) | ~350 MiB |
| Runtime detection | **Falco**, Tetragon, KubeArmor | **Falco, modern_ebpf** (below) | ~450 MiB (3 nodes) |
| In-cluster continuous scanning | Trivy Operator, Kubescape | **Skip for now.** CI scans every image, and RAM is better spent on Phase 7 | — |

### Admission: why Kyverno

| | Kyverno 1.19 | VAP (built-in) | Gatekeeper | policy-controller |
|---|---|---|---|---|
| Structural rules (limits, labels, registries, host*) | ✓ YAML or CEL | ✓ CEL | ✓ Rego | ✗ |
| **Image signature / attestation verification** | ✓ native (keyless, Rekor) | ✗ | needs external data provider | ✓ (only that) |
| Audit → enforce per policy | ✓ `Audit`/`Enforce` + PolicyReports | ✓ `Audit`/`Warn`/`Deny` (audit annotations only) | ✓ dryrun + audit | ✓ warn/enforce |
| Background scan of existing resources | ✓ PolicyReports (feeds Phase 7 dashboards) | ✗ | ✓ | ✗ |
| Footprint | 3 controllers, ~350 MiB trimmed | 0 | ~300 MiB | ~100 MiB |
| Language | YAML/CEL (closest to K8s) | CEL | Rego (another language) | YAML |

Kyverno is the only single tool that covers all eight required policy areas,
including image integrity, with reportable audit mode. A **lean alternative**,
VAP for structure plus policy-controller for signatures (~100 MiB), is viable,
but it has no background reports and is split across two tools.
Gatekeeper's Rego adds a language without adding coverage here.

### Runtime: why Falco
- The largest maintained rule library (shell in container, sensitive file reads, package managers at runtime, unexpected outbound connections, K8s client in a pod…) gives useful detections out of the box.
- `modern_ebpf` driver: CO-RE probe bundled in the binary, kernel 6.10 + BTF confirmed.
- **Cost:** a DaemonSet (one pod per node, ~150 MiB each). It needs a **privileged** namespace. That's a deliberate, documented Pod Security exception, since a runtime sensor must see host syscalls.
- **Tetragon** (Cilium's eBPF sensor) is the strongest alternative. It integrates with the Cilium we already run and can *enforce* (kill a process), but it ships far fewer ready-made detections. Good candidate for later work.
- Falco **detects**; it doesn't block. Prevention stays with admission (Kyverno and PSA) and network policy (Phase 6).

## Proposed policies (Kyverno, audit first, then enforce)

| # | Policy | Rule | Overlap with PSA | Enforcement scope |
|---|---|---|---|---|
| 1 | Disallow privileged containers | `securityContext.privileged != true` | yes (defence in depth, also covers PSA-exempt namespaces) | all non-system namespaces |
| 2 | Require run as non-root | `runAsNonRoot: true`, `runAsUser != 0` | yes | same |
| 3 | Require resource limits | every container has `limits.memory` and `requests.cpu/memory` **set explicitly** (LimitRange defaults don't count) | no | `demo-*` |
| 4 | Restrict image registries | images from `ghcr.io/resumepilot360/*` or `k3d-registry.localhost:5001/*` only | no | `demo-*`, `lab-*` |
| 5 | Disallow host networking / ports / PID / IPC | `hostNetwork/hostPID/hostIPC != true`, no `hostPort` | yes | all non-system namespaces |
| 6 | Disallow hostPath | no `hostPath` volumes | yes | all non-system namespaces |
| 7 | Require metadata | `app.kubernetes.io/name` and `app.kubernetes.io/part-of` on workloads; `lab.platform/environment` on namespaces | no | `demo-*` |
| 8 | Verify image signatures | `ghcr.io/resumepilot360/*` must be **Cosign-signed by this repo's `ci.yaml` on `main`** (keyless: issuer `token.actions.githubusercontent.com`, subject `…/.github/workflows/ci.yaml@refs/heads/main`), plus a CycloneDX SBOM attestation | no | `demo-*` |
| 9 | Restrict ServiceAccount use (Phase 2 finding) | in `demo-*`, pods may only use `default` or `demo-backend` (blocks running as `eso-reader`/`config-reader`) | no | `demo-*` |

Exclusions are scoped explicitly. `kube-system`, `argocd`, `openbao`, `external-secrets`
and `falco` are excluded from policies 3, 4, 7 and 8 because third-party charts use
upstream registries. Everything excluded is listed in the policy, and the
exclusions are covered by tests.

**Rollout:** all policies start in `Audit`. Existing violations are reviewed from
PolicyReports and fixed. Then they switch to `Enforce` one by one, and the tests
prove that a violating manifest is rejected *and* that a compliant one is admitted.

## CI additions
1. **Trivy config** on every `kubectl kustomize` output (fail on HIGH/CRITICAL misconfigurations).
2. **Syft** SBOM (CycloneDX) per image digest.
3. **Cosign keyless**: `cosign sign` and `cosign attest --type cyclonedx`, both by digest. Needs only `id-token: write` on the build job.
4. **Dependabot** for GitHub Actions, Docker base images and Go modules.
5. `cosign verify` in `deploy-dev` before pinning, so CI refuses to deploy what it can't verify.

## Resource and risk summary
- In-cluster: **Kyverno ~350 MiB + Falco ~450 MiB ≈ 0.8 GiB.** Projected total ~5.2 GiB, leaving ~3 GiB headroom for Phase 7.
- Risk: **Kyverno is a webhook.** If it's down while `failurePolicy: Fail`, matching pods can't be created. Mitigations: system namespaces excluded at the webhook level, `Ignore` during audit, runbook for webhook outages.
- Risk: Falco noise. It starts with the default ruleset plus lab-specific tuning (k3d and Cilium generate expected privileged activity), documented in a runbook.
- Risk: **Signature verification depends on Rekor/Fulcio reachability** from the cluster. Offline, pods with new images are denied. That's acceptable for the lab and documented.
