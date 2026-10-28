# Runbook: GitOps delivery (CI → Argo CD → dev/staging/prod)

## Normal flow

| Step | Who / what | How to observe |
|---|---|---|
| 1. Change code under `applications/` and merge to `main` | developer | PR checks: `ci` (tests, govulncheck, Semgrep, build, Trivy) |
| 2. Images pushed to GHCR as `sha-<short>` | `ci` → build job | https://github.com/resumepilot360?tab=packages |
| 3. Dev digests pinned in `gitops/environments/dev` | `ci` → deploy-dev job (bot commit) | `git log -- gitops/environments/dev` |
| 4. Argo CD syncs dev and runs the PostSync smoke test | Argo CD (auto) | http://argocd.lab.localhost:8081 → `demo-dev`; http://demo.dev.lab.localhost:8081 |
| 5. Promote to staging | `gh workflow run promote -f to=staging`, then merge the PR | PR "promote(staging)…"; Argo CD `demo-staging` |
| 6. Promote to prod | `gh workflow run promote -f to=prod` → **approve** the `production` deployment in GitHub → merge the PR | Actions run page shows "Waiting for review" |
| 7. Sync prod | Argo CD UI → `demo-prod` → Sync (or the CLI below) | `demo-prod` Synced/Healthy, smoke hook green |

```bash
# Argo CD admin password (local only)
kubectl --context k3d-platform-lab -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# Manual prod sync without the UI
kubectl --context k3d-platform-lab -n argocd patch application demo-prod --type merge \
  -p '{"operation":{"initiatedBy":{"username":"'"$USER"'"},"sync":{"revision":"main"}}}'
# Status of everything
kubectl --context k3d-platform-lab -n argocd get applications
```

## Rollback

Rollback is a Git operation. Argo CD follows.
```bash
git log --oneline -- gitops/environments/prod     # find the promotion commit
git revert <sha> && git push                       # dev/staging: Argo CD auto-syncs back
# prod: then sync demo-prod (manual gate applies to rollbacks too)
```
Don't use Argo CD's History → Rollback on auto-synced apps: self-heal reverts it on the next reconcile.

## Drift

| Env | Someone runs `kubectl scale/edit/delete` | Result |
|---|---|---|
| dev, staging | self-heal reverts within ~1 reconcile (≤ 60s) | App briefly OutOfSync, then Synced |
| prod | Argo CD marks it **OutOfSync** and leaves it | A human decides: sync (revert the drift) or commit the change to Git |

Who did it: K8s audit log, `select(.objectRef.namespace=="demo-prod" and .verb=="patch")`.

## Troubleshooting

| Symptom | Evidence | Fix |
|---|---|---|
| App `Degraded`, pods `ImagePullBackOff` | `kubectl -n demo-dev describe pod` → `not found` / `denied` | Image not yet built (CI still running), or the GHCR package is private: set it public in GitHub → Packages → settings |
| App `OutOfSync` with a "not permitted in project" condition | `kubectl -n argocd get application <a> -o yaml` → `.status.conditions` | The manifest contains a kind blacklisted for `demo` (Secret, Role, NetworkPolicy…). Move it to platform config |
| Sync `Failed` at PostSync | `kubectl -n demo-dev logs job/smoke-test` | `FAIL: backend has no DB credentials` → check ExternalSecret (secrets runbook). `greeting missing` → app regression: roll back |
| Promotion workflow fails "without a digest pin" | Actions log | Source env still has `newTag: unreleased`. Promote dev first |
| `deploy-dev` job push rejected | Actions log | Concurrent commit; the job retries 3 times. Re-run the job |
| Root app shows Applications OutOfSync after editing them with kubectl | expected | The root app owns Application objects. Edit them in `gitops/applications/` |
