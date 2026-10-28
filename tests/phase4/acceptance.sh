#!/usr/bin/env bash
# Phase 4 acceptance: Argo CD health, GitOps delivery to dev/staging/prod,
# PostSync verification, digest traceability, AppProject guardrails, drift
# detection + reconciliation (auto in dev, manual in prod).
source "$(dirname "$0")/../../scripts/lib.sh"
REPO="$GITOPS_REPO_URL"
app_state() { kc -n argocd get application "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
is_state()  { [[ "$(app_state "$1")" == "$2" ]]; }
wait_state() { local a="$1" want="$2" t="${3:-180}"; for _ in $(seq 1 $((t/5))); do is_state "$a" "$want" && return 0; sleep 5; done; return 1; }
cleanup() { kc -n argocd delete application p4-guardrail-ns p4-guardrail-secret --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Argo CD"
check "Argo CD UI served via ingress" bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' http://argocd.lab.localhost:$INGRESS_HTTP_PORT/) == 200 ]]"
check "initial admin secret exists"   kc -n argocd get secret argocd-initial-admin-secret
check "root app-of-apps Synced/Healthy" is_state root Synced/Healthy
for a in platform-namespaces platform-rbac platform-secret-stores lab-portal; do
  check "$a Synced/Healthy" is_state "$a" Synced/Healthy
done
check "platform-rbac owns lab:platform-operator" bash -c \
  "kubectl --context $KUBE_CONTEXT get clusterrole lab:platform-operator -o jsonpath='{.metadata.annotations}' | grep -q argocd"

echo "== Delivery"
for env in dev staging prod; do
  check "demo-$env Synced/Healthy" wait_state "demo-$env" Synced/Healthy 240
  check "demo-$env PostSync smoke hook succeeded" bash -c \
    "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-$env get job smoke-test -o jsonpath='{.status.succeeded}') == 1 ]]"
  for app in demo-backend demo-frontend; do
    pin=$(yq ".images[] | select(.name==\"$app\") | .digest" "$LAB_ROOT/gitops/environments/$env/kustomization.yaml")
    check "demo-$env $app pinned by digest in Git" bash -c "[[ '$pin' == sha256:* ]]"
    check "demo-$env $app running the pinned digest" bash -c \
      "kubectl --context $KUBE_CONTEXT -n demo-$env get pods -l app.kubernetes.io/name=$app -o jsonpath='{.items[*].spec.containers[0].image}' | tr ' ' '\n' | sort -u | grep -qx '.*@$pin'"
  done
  check "http://demo.$env.lab.localhost: frontend -> backend -> secret" bash -c \
    "curl -fsS -m 5 http://demo.$env.lab.localhost:$INGRESS_HTTP_PORT/ | grep -q 'env demo-$env · db configured: true'"
done
check "prod has no automated sync (manual gate)" bash -c \
  "[[ -z \$(kubectl --context $KUBE_CONTEXT -n argocd get application demo-prod -o jsonpath='{.spec.syncPolicy.automated}') ]]"
check "staging and prod run the same digests as each other" bash -c \
  "diff <(yq '.images' $LAB_ROOT/gitops/environments/staging/kustomization.yaml) <(yq '.images' $LAB_ROOT/gitops/environments/prod/kustomization.yaml)"

echo "== AppProject guardrails"
guard_app() { # name path dest-ns
  kc apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: $1, namespace: argocd}
spec:
  project: demo
  source: {repoURL: $REPO, targetRevision: main, path: $2}
  destination: {server: https://kubernetes.default.svc, namespace: $3}
  syncPolicy: {automated: {prune: false, selfHeal: false}}
YAML
}
guard_app p4-guardrail-ns     gitops/environments/dev kube-system
guard_app p4-guardrail-secret tests/phase4/fixtures/forbidden-secret demo-dev
sleep 20
check "demo project refuses destination kube-system" bash -c \
  "kubectl --context $KUBE_CONTEXT -n argocd get application p4-guardrail-ns -o json | jq -e '[.status.conditions[]?.message] | any(test(\"not permitted|do not match any of the allowed destinations\"))'"
check "demo project refuses to sync a Secret" bash -c \
  "kubectl --context $KUBE_CONTEXT -n argocd get application p4-guardrail-secret -o json | jq -e '[(.status.conditions[]?.message), (.status.operationState.message // \"\"), (.status.operationState.syncResult.resources[]?.message // \"\")] | any(test(\"not permitted\"))'"
check "...and the Secret does not exist" bash -c "! kubectl --context $KUBE_CONTEXT -n demo-dev get secret should-never-sync"
cleanup

echo "== Drift: dev self-heals"
kc -n demo-dev scale deploy/demo-backend --replicas=3 >/dev/null
kc -n demo-dev delete service demo-frontend >/dev/null
heal() { [[ $(kc -n demo-dev get deploy demo-backend -o jsonpath='{.spec.replicas}') == 1 ]] && kc -n demo-dev get service demo-frontend >/dev/null 2>&1; }
for _ in $(seq 1 36); do heal && break; sleep 5; done
check "manual scale reverted to Git (1 replica)" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-dev get deploy demo-backend -o jsonpath='{.spec.replicas}') == 1 ]]"
check "deleted Service recreated" kc -n demo-dev get service demo-frontend
check "demo-dev back to Synced/Healthy" wait_state demo-dev Synced/Healthy 180

echo "== Drift: prod is detected, not auto-reverted"
kc -n demo-prod scale deploy/demo-backend --replicas=3 >/dev/null
check "prod drift detected (OutOfSync)" bash -c \
  "for i in \$(seq 1 30); do [[ \$(kubectl --context $KUBE_CONTEXT -n argocd get application demo-prod -o jsonpath='{.status.sync.status}') == OutOfSync ]] && exit 0; sleep 5; done; exit 1"
check "prod drift left in place (no self-heal)" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-prod get deploy demo-backend -o jsonpath='{.spec.replicas}') == 3 ]]"
kc -n argocd patch application demo-prod --type merge -p '{"operation":{"initiatedBy":{"username":"phase4-test"},"sync":{"revision":"main"}}}' >/dev/null
check "manual sync reconciles prod to Git (2 replicas)" bash -c \
  "for i in \$(seq 1 36); do [[ \$(kubectl --context $KUBE_CONTEXT -n demo-prod get deploy demo-backend -o jsonpath='{.spec.replicas}') == 2 ]] && exit 0; sleep 5; done; exit 1"
check "demo-prod back to Synced/Healthy" wait_state demo-prod Synced/Healthy 240

summary
