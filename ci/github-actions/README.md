# CI (GitHub Actions)

GitHub only runs workflows from `.github/workflows/`, so the workflows live
there, not here (deviation from the proposed layout, recorded in ADR-0009):

| Workflow | Trigger | Does |
|---|---|---|
| [`ci.yaml`](../../.github/workflows/ci.yaml) | push/PR touching `applications/**` | vet, unit + integration tests, govulncheck, Semgrep, build, Trivy image scan; on `main`: push to GHCR and pin digests in `gitops/environments/dev` |
| [`promote.yaml`](../../.github/workflows/promote.yaml) | manual (`gh workflow run promote -f to=staging`) | copies digests dev→staging or staging→prod and opens a PR; prod requires the `production` environment approval |
| [`validate.yaml`](../../.github/workflows/validate.yaml) | push/PR touching manifests | kustomize build + kubeconform (strict) for every kustomization |

Identity: workflows use the short-lived `GITHUB_TOKEN` (GHCR push, commits,
PRs) with per-job least-privilege `permissions:`. No cloud credentials exist
yet. On AWS, `ci.yaml` gains an OIDC → `sts:AssumeRoleWithWebIdentity` step
for an ECR-push-only role (docs/iam-model.md).
