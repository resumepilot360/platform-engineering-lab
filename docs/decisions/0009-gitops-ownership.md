# ADR-0009: GitOps with Argo CD; one owner per resource; digest-based promotion

- Status: Accepted (2026-10-28)

## Ownership

Every resource has exactly one owner. No resource is applied both by a script and by Argo CD.

| Layer | Owner | Local | AWS |
|---|---|---|---|
| Infrastructure | Terraform | — | VPC, EKS, IAM, KMS, ECR, Secrets Manager |
| Cluster bootstrap | `scripts/cluster-up.sh` (local) / Terraform + EKS add-ons (AWS) | k3d cluster, Cilium, bootstrap namespaces (`local/bootstrap`), ESO + OpenBao Helm releases, OpenBao init/unseal, Argo CD + root app | EKS managed add-ons (VPC CNI, CoreDNS), Argo CD Helm release, root app |
| Platform config | **Argo CD**, project `platform` | `platform/namespaces`, `platform/rbac`, `platform/secrets/stores`, `platform/portal` | same |
| Applications | **Argo CD**, project `demo` | `gitops/environments/{dev,staging,prod}` | same |
| Image builds | GitHub Actions | GHCR | ECR (via OIDC role) |

Consequences:
- Scripts and tests never `kubectl apply` Argo-owned paths. Phase 2's RBAC test now asserts that `platform-rbac` is Synced instead of applying it.
- Test-only resources (Phase 1 smoke workloads) live in `lab-smoke`. Argo CD owns the namespace but not its contents.

## Delivery model

- **Kustomize everywhere for first-party manifests** (ADR-0005). Helm is used only for third-party charts.
- **App-of-apps**: `gitops/bootstrap/root.yaml` → `gitops/applications/` (projects + Applications, ordered by sync waves).
- **Images are referenced by digest.** CI pins `newName@digest` in `gitops/environments/dev`. Promotion copies those digests unchanged, so the bytes tested in dev are the bytes that run in prod. Tags are never promoted; `promote.yaml` refuses images without a digest.
- **Environments:**

  | Env | Change path | Argo CD sync |
  |---|---|---|
  | dev | CI commits to `main` on every merged app change | automated, prune, self-heal |
  | staging | `promote -f to=staging` opens a PR; merge it | automated, prune, self-heal |
  | prod | `promote -f to=prod` waits for **production environment approval**, opens a PR; merge it | **manual**: OutOfSync until a human syncs |

- **Health verification:** Deployment readiness (the backend is ready only with
  its secret mounted; the frontend only while the backend answers) plus a
  **PostSync smoke-test Job** that exercises frontend → backend → secret. A failed hook fails the sync.
- **Rollback:** `git revert` of the deploy or promotion commit. Argo CD returns the
  environment to the previous digests. Argo CD's own history rollback is
  deliberately unused for auto-synced apps, because self-heal would undo it, and Git must stay the source of truth.

## Guardrails (AppProject `demo`)
- Destinations limited to `demo-dev`, `demo-staging`, `demo-prod`.
- No cluster-scoped resources.
- Blacklisted kinds: `Secret`, `ResourceQuota`, `LimitRange`, `Role`, `RoleBinding`,
  `NetworkPolicy`, `SecretStore`, `ExternalSecret`. Apps can't grant themselves access,
  remove their limits, or ship credentials through Git. These are tested with fixtures.
- Namespaces carry `argocd.argoproj.io/sync-options: Delete=false`, so removing one from Git can't cascade-delete it.

## Known gaps
- **No SSO.** Argo CD RBAC maps `lab:*` groups, but only the local `admin` account
  exists until an OIDC provider supplies groups (Dex/OIDC, deferred with Phase 2b).
  Using `admin` daily is the local compromise.
- **The Argo CD UI is HTTP on loopback** until Phase 6 adds TLS.
- **Bot commits to `main`:** CI pushes dev pins directly, so `main` can't
  require PRs for every change. Production alternative: a GitHub App with a
  ruleset bypass for the deploy bot, while humans go through PRs.
- **PRs opened by `GITHUB_TOKEN` don't trigger workflows**, so promotion PRs
  aren't re-validated by `validate.yaml`. Argo CD's render step is the backstop.
  Production alternative: a GitHub App token for promotion.
- **Repository and images are public.** No secrets are in Git (scanned each phase).
  Private repos would need Argo CD repo credentials and an image-pull secret,
  both deliverable via ESO.
- Workflows live in `.github/workflows/` (GitHub requirement), not `ci/github-actions/`.
