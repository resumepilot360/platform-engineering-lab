# Runbook: admission policies (Kyverno) and runtime detection (Falco)

## Status at a glance
```bash
kubectl --context k3d-platform-lab get clusterpolicy,imagevalidatingpolicy
kubectl --context k3d-platform-lab get policyreport -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .results[]? | select(.result=="fail") | "\($ns) \(.policy): \(.message)"'
tests/phase5/acceptance.sh
```

## Rollout: audit → enforce
1. New or changed policy merges with `failureAction: Audit` (ClusterPolicy rules) or
   `validationActions: [Audit]` (ImageValidatingPolicy).
2. Review PolicyReports for failing results on **current** pods. Failures on old
   ReplicaSets (kept by `revisionHistoryLimit`) describe history, not running workloads.
3. Fix the workloads, never the policy. For images, that usually means promoting a
   signed digest (`gh workflow run promote -f to=…`).
4. Change to `Enforce` / `[Deny]` in Git and merge. Argo CD syncs `platform-policies`.
5. Run `tests/phase5/acceptance.sh`. Every deny check also has a positive control.

## A workload is denied
Evidence: `kubectl apply` error or Argo CD sync message: `admission webhook "…kyverno…" denied the request: policy <name>…`

| Policy | Typical cause | Fix |
|---|---|---|
| `verify-image-signatures` | Image built outside `ci.yaml` on `main` (local build, fork, tag edit) | Build through CI; promote the signed digest. Verify: `cosign verify --certificate-identity https://github.com/resumepilot360/platform-engineering-lab/.github/workflows/ci.yaml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com <image@digest>` |
| `restrict-image-registries` | Upstream image referenced directly | Mirror it into `k3d-registry.localhost:5001/lab/` (`scripts/seed-registry.sh`) |
| `require-requests-limits` | Template lacks `requests.cpu/memory` or `limits.memory` | Add them explicitly (LimitRange defaults don't count) |
| `require-labels` | Missing `app.kubernetes.io/name` / `part-of`, or a namespace without `lab.platform/environment` | Add labels |
| `restrict-service-accounts` | Pod uses `eso-reader`, `config-reader`, … | Use `default` or a purpose-made, platform-owned SA |
| host / privileged / root | Insecure securityContext | Fix the manifest; no exceptions for app namespaces |

### Exceptions (time-boxed, platform-owned)
Only the `kyverno` namespace may hold `PolicyException` objects (`features.policyExceptions.namespace`).
Create one through Git with an expiry note in its annotations, scoped to exact names. Never edit the policy instead.

## Kyverno itself is down
Symptom: Pod creation in matched namespaces fails with `failed calling webhook … kyverno-svc … connection refused`.
System namespaces (`kube-system`, `kyverno`) are excluded at the webhook, so Kyverno can always restart.
```bash
kubectl --context k3d-platform-lab -n kyverno get pods
kubectl --context k3d-platform-lab -n kyverno logs deploy/kyverno-admission-controller --tail=100
kubectl --context k3d-platform-lab -n kyverno rollout restart deploy/kyverno-admission-controller
```
Last resort (break-glass, audited): temporarily set the policies back to Audit in Git. Don't delete webhooks by hand,
because Kyverno recreates them and the change bypasses review.

## Signature verification fails for a correctly signed image
- `x509: certificate signed by unknown authority`: stale Sigstore trust root. Check that `--enableTuf=true` is on the
  admission/reports controllers and that `tuf-repo-cdn.sigstore.dev`, `fulcio.sigstore.dev` and `rekor.sigstore.dev` resolve from a pod.
- `no signatures found`: the digest predates signing or was built elsewhere. Rebuild through CI.

## Falco alerts
```bash
kubectl --context k3d-platform-lab -n falco logs ds/falco -c falco --since=1h | grep '^{' | jq -r '"\(.time) \(.priority) \(.rule) ns=\(.output_fields["k8s.ns.name"]) pod=\(.output_fields["k8s.pod.name"]) cmd=\(.output_fields["proc.cmdline"])"'
```
Triage: who exec'd? Match the alert time with the K8s audit log (`pods/exec` events: user, pod, time).
`Shell in lab application container` in a `demo-*` namespace is never expected (distroless images), except for
`smoke-test-*` hook pods, which are excluded.
Tuning goes in `platform/runtime/falco/values.yaml` (`customRules`). Every exclusion carries a comment saying why.
