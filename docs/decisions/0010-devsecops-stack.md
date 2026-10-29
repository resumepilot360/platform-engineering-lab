# ADR-0010: DevSecOps stack — CI scanners, keyless signing, Kyverno, Falco

- Status: Accepted (2026-10-29). Evaluation: [phase-5-tool-evaluation.md](../phase-5-tool-evaluation.md)

## Decision

| Layer | Tool | Where |
|---|---|---|
| SAST | Semgrep (`p/golang`, `p/secrets`, `p/dockerfile`) | `ci.yaml` |
| Dependencies | govulncheck (reachable vulns only) + Dependabot | `ci.yaml`, `.github/dependabot.yml` |
| Image vulnerabilities | Trivy: amd64 candidate pre-push, arm64 digest post-push | `ci.yaml` |
| Manifest / IaC misconfiguration | Trivy config on every rendered kustomization and on `terraform/` | `validate.yaml`, `terraform.yaml` |
| SBOM | Syft, CycloneDX, per digest | `ci.yaml` |
| Signing | Cosign **keyless**: GitHub OIDC → Fulcio cert → Rekor; signature + SBOM attestation | `ci.yaml` |
| Deploy gate | `cosign verify` + `verify-attestation` in `deploy-dev` before pinning | `ci.yaml` |
| Admission | Kyverno 1.19: 8 `ClusterPolicy` + 1 `ImageValidatingPolicy`, audit first → enforce | `platform/policies` (Argo CD) |
| Runtime | Falco 0.45, `modern_ebpf`, least-privileged capabilities | `platform/runtime/falco` (bootstrap) |

## Notable choices and findings
- **Keyless signing:** there's no key to leak or rotate. Trust is "the workflow file
  `ci.yaml` on `refs/heads/main` of this repository", checked by both CI and Kyverno.
  A signature made from a fork, a branch or another workflow fails verification (tested).
- **`ImageValidatingPolicy` for signatures, not `ClusterPolicy` `verifyImages`.**
  Side by side, the deprecated `verifyImages` path rejected CI-signed images with
  `x509: certificate signed by unknown authority`, while `ImageValidatingPolicy`
  (current Sigstore trusted root) verified them and still rejected unsigned digests.
  Kyverno TUF is enabled, so the trust root is fetched rather than embedded.
- **The other 8 policies remain `ClusterPolicy`.** They work, but Kyverno 1.19 marks
  the API deprecated. Migrating them to `ValidatingPolicy` (CEL) is tracked as follow-up.
- **Explicit limits are enforced on controllers.** `LimitRange` defaults Pods
  before validation, so the rule only bites on Deployment/Job templates (Kyverno
  autogen). That's the point where a missing limit is a manifest bug.
- **Defence in depth with PSA.** Privileged, root, host namespaces and hostPath are
  blocked by both PSA (`restricted`) and Kyverno. Tests prove Kyverno alone blocks
  them in a namespace where PSA is `privileged`.
- **Falco is a documented Pod Security exception** (`falco` namespace = `privileged`)
  but runs with 4 capabilities, not `privileged: true`. It detects; it does not block.
- **Argo CD server-side diff** on `platform-policies`, so Kyverno's defaulting webhook
  isn't reported as drift.

## Consequences
- Kyverno is in the admission path: if it is down, Pods in matched namespaces
  can't be created (`failurePolicy: Fail`). System namespaces are excluded at the
  webhook. Recovery: [runbook](../runbooks/policy-enforcement.md).
- Image verification needs Rekor/Fulcio/TUF reachability. Offline clusters need a
  mirrored trust root (TUF mirror) or a private Sigstore.
- AWS: identical Kyverno policies with the registry allow-list changed to ECR, plus
  GuardDuty EKS Runtime Monitoring as a managed alternative to Falco.
