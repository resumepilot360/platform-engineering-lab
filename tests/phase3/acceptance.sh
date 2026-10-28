#!/usr/bin/env bash
# Phase 3 acceptance: encryption at rest, OpenBao health and persistence,
# External Secrets delivery, environment separation, access restrictions,
# rotation (app secret and datastore key), and leak checks.
#
# Negative checks are paired with a positive control so a broken check cannot
# pass silently (e.g. the plaintext ConfigMap canary must be found on disk).
source "$(dirname "$0")/../../scripts/lib.sh"
ID="$LAB_ROOT/.tools/identities"; SEC="$LAB_ROOT/.tools/secrets"
SRV="k3d-$CLUSTER_NAME-server-0"
DB="/var/lib/rancher/k3s/server/db"

PORT=18202; ADDR="http://127.0.0.1:$PORT"
kc -n openbao port-forward pod/openbao-0 "$PORT:8200" >/dev/null 2>&1 & pf=$!
cleanup() { kill $pf 2>/dev/null || true; kc delete -n demo-dev secret,configmap phase3-canary --ignore-not-found >/dev/null 2>&1
            kc delete -n demo-dev secretstore,externalsecret -l lab.platform/test=phase3 --ignore-not-found >/dev/null 2>&1
            kc delete -n demo-staging secretstore,externalsecret -l lab.platform/test=phase3 --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT
for _ in $(seq 1 30); do curl -fsS "$ADDR/v1/sys/health" >/dev/null 2>&1 && break; sleep 1; done
bao() { curl -s -o /dev/null -w '%{http_code}' -H "X-Vault-Token: $1" "$ADDR/v1/$2"; }   # bao TOKEN PATH -> http code
secret_val() { kc -n "$1" get secret demo-backend-db -o jsonpath="{.data.$2}" | base64 -d; }
on_disk() { docker exec "$SRV" sh -c "cat $DB/state.db $DB/state.db-wal 2>/dev/null | grep -a -c -- '$1'" 2>/dev/null | grep -qv '^0$'; }

echo "== Encryption at rest (K3s datastore)"
check "secrets-encrypt status Enabled" bash -c "docker exec $SRV k3s secrets-encrypt status 2>/dev/null | grep -q 'Encryption Status: Enabled'"
check "active provider is secretbox"   bash -c "docker exec $SRV k3s secrets-encrypt status 2>/dev/null | grep -qi 'secretbox'"
not_on_disk() { ! on_disk "$1"; }
# Independent random values so neither canary is a substring of the other.
canary="sec-$(openssl rand -hex 12)"; cm_canary="cm-$(openssl rand -hex 12)"
kc -n demo-dev create secret generic phase3-canary --from-literal=v="$canary" >/dev/null
kc -n demo-dev create configmap     phase3-canary --from-literal=v="$cm_canary" >/dev/null
sleep 2
check "control: ConfigMap canary IS plaintext on disk" on_disk "$cm_canary"
check "Secret canary NOT plaintext on disk"            not_on_disk "$canary"
check "Secret stored with k8s:enc:secretbox prefix" on_disk 'k8s:enc:secretbox:v1:'
check "Secret still readable through the API" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-dev get secret phase3-canary -o jsonpath='{.data.v}' | base64 -d) == $canary ]]"

echo "== OpenBao"
check "initialised and unsealed" bash -c "curl -fsS $ADDR/v1/sys/seal-status | jq -e '.initialized and (.sealed|not)'"
check "unseal material is mode 600 and gitignored" bash -c \
  "[[ \$(stat -f %Lp $SEC/openbao-init.json) == 600 ]] && git -C $LAB_ROOT check-ignore -q $SEC/openbao-init.json"
check "audit device enabled" bash -c "curl -fsS -H \"X-Vault-Token: \$(jq -r .root_token $SEC/openbao-init.json)\" $ADDR/v1/sys/audit | jq -e '.data[\"stdout/\"]'"
OP="$(cat "$SEC/openbao-operator.token")"
check "operator token cannot write policies"     test "$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "X-Vault-Token: $OP" -d '{"policy":"path \"*\" {capabilities=[\"sudo\"]}"}' "$ADDR/v1/sys/policies/acl/pwn")" = 403
check "operator token cannot read sys/audit"     test "$(bao "$OP" sys/audit)" = 403

echo "== External Secrets delivery"
for ns in demo-dev demo-staging; do
  check "$ns SecretStore Ready"          kc -n $ns wait --for=condition=Ready secretstore/openbao --timeout=60s
  check "$ns ExternalSecret synced"      kc -n $ns wait --for=condition=Ready externalsecret/demo-backend-db --timeout=90s
  check "$ns Secret has 3 keys"          bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n $ns get secret demo-backend-db -o json | jq '.data|length') -eq 3 ]]"
  check "$ns Secret owned by its ExternalSecret" bash -c \
    "kubectl --context $KUBE_CONTEXT -n $ns get secret demo-backend-db -o jsonpath='{.metadata.ownerReferences[0].kind}' | grep -qx ExternalSecret"
done
check "dev Secret carries dev username"         test "$(secret_val demo-dev db_username)" = demo_dev
check "staging Secret carries staging username" test "$(secret_val demo-staging db_username)" = demo_staging
check "dev and staging passwords differ" test "$(secret_val demo-dev db_password)" != "$(secret_val demo-staging db_password)"
check "ExternalSecret manifests in Git contain no values" bash -c \
  "! grep -rqE 'db_password:|api_key:' $LAB_ROOT/platform/secrets/stores"

echo "== Access restrictions: OpenBao"
LOGIN_OUT="$(mktemp)"
login() { # ns sa role [audience] -> http code; response body in $LOGIN_OUT
  local jwt; jwt=$(kc -n "$1" create token "$2" --duration=10m ${4:+--audience="$4"})
  jq -n --arg r "$3" --arg j "$jwt" '{role:$r, jwt:$j}' \
    | curl -s -o "$LOGIN_OUT" -w '%{http_code}' -X POST --data-binary @- "$ADDR/v1/auth/kubernetes/login"
}
check "control: dev eso-reader + audience=openbao logs in to eso-demo-dev" test "$(login demo-dev eso-reader eso-demo-dev openbao)" = 200
DEVTOK=$(jq -r .auth.client_token "$LOGIN_OUT")
check "dev token policies = [default, demo-dev-read]" jq -e '.auth.token_policies == ["default","demo-dev-read"]' "$LOGIN_OUT"
check "dev token reads kv-dev"                     test "$(bao "$DEVTOK" kv-dev/data/demo/backend)" = 200
check "dev token DENIED kv-staging"                test "$(bao "$DEVTOK" kv-staging/data/demo/backend)" = 403
check "dev token DENIED listing secrets"           test "$(bao "$DEVTOK" 'kv-dev/metadata/demo?list=true')" = 403
check "default-audience token rejected (403)"      test "$(login demo-dev eso-reader eso-demo-dev)" = 403
check "staging SA cannot use dev role (403)"       test "$(login demo-staging eso-reader eso-demo-dev openbao)" = 403
check "other SA in demo-dev cannot use role (403)" test "$(login demo-dev demo-backend eso-demo-dev openbao)" = 403
rm -f "$LOGIN_OUT"

echo "== Access restrictions: through ESO"
# A SecretStore in demo-dev pointed at the staging mount must fail on policy.
kc apply -f - >/dev/null <<'YAML'
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: {name: steal-staging, namespace: demo-dev, labels: {lab.platform/test: phase3}}
spec:
  provider:
    vault:
      server: http://openbao.openbao.svc:8200
      path: kv-staging
      version: v2
      auth: {kubernetes: {mountPath: kubernetes, role: eso-demo-dev, serviceAccountRef: {name: eso-reader, audiences: ["openbao"]}}}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: steal-staging, namespace: demo-dev, labels: {lab.platform/test: phase3}}
spec:
  refreshInterval: 1m
  secretStoreRef: {kind: SecretStore, name: steal-staging}
  target: {name: stolen-staging}
  dataFrom: [{extract: {key: demo/backend}}]
YAML
sleep 15
check "dev ExternalSecret for staging data fails" bash -c \
  "kubectl --context $KUBE_CONTEXT -n demo-dev get externalsecret steal-staging -o jsonpath='{.status.conditions[0].status}' | grep -qx False"
check "...and no Secret was created" bash -c "! kubectl --context $KUBE_CONTEXT -n demo-dev get secret stolen-staging"

echo "== Access restrictions: Kubernetes RBAC"
# Re-issue unless the cert still authenticates: a cluster rebuild changes the CA,
# and a 401 would make every CANNOT check below pass for the wrong reason.
authenticates() { KUBECONFIG="$ID/$1.kubeconfig" kubectl auth whoami >/dev/null 2>&1; }
for u in alice dana riley; do
  authenticates "$u" || {
    case $u in alice) g=lab:platform-admins;; dana) g=lab:developers;; riley) g=lab:auditors;; esac
    "$LAB_ROOT/scripts/issue-user-cert.sh" "$u" "$g" >/dev/null; }
  check "$u credentials authenticate (precondition)" authenticates "$u"
done
as() { local u="$1"; shift; KUBECONFIG="$ID/$u.kubeconfig" kubectl "$@"; }
check "dana CANNOT read synced Secret"            bash -c "! KUBECONFIG=$ID/dana.kubeconfig kubectl auth can-i get secret/demo-backend-db -n demo-dev"
check "dana CAN see ExternalSecret status"        as dana -n demo-dev get externalsecret demo-backend-db
check "dana CANNOT create SecretStores"           bash -c "! KUBECONFIG=$ID/dana.kubeconfig kubectl auth can-i create secretstores.external-secrets.io -n demo-dev"
check "riley CANNOT read synced Secret"           bash -c "! KUBECONFIG=$ID/riley.kubeconfig kubectl auth can-i get secrets -n demo-staging"
check "alice CANNOT create ClusterSecretStores"   bash -c "! KUBECONFIG=$ID/alice.kubeconfig kubectl auth can-i create clustersecretstores.external-secrets.io"

echo "== Rotation: application secret"
before_dev=$(secret_val demo-dev db_password); before_stg=$(secret_val demo-staging db_password)
"$LAB_ROOT/scripts/rotate-secret.sh" dev >/dev/null
for _ in $(seq 1 24); do [[ "$(secret_val demo-dev db_password)" != "$before_dev" ]] && break; sleep 5; done
check "dev Secret updated within 2 min of rotation" test "$(secret_val demo-dev db_password)" != "$before_dev"
check "dev Secret matches OpenBao's new value" bash -c \
  "[[ \$(curl -fsS -H 'X-Vault-Token: $OP' $ADDR/v1/kv-dev/data/demo/backend | jq -r .data.data.db_password) == \"\$1\" ]]" _ "$(secret_val demo-dev db_password)"
check "staging untouched by dev rotation" test "$(secret_val demo-staging db_password)" = "$before_stg"
check "previous version retained for rollback" bash -c \
  "curl -fsS -H 'X-Vault-Token: $OP' $ADDR/v1/kv-dev/metadata/demo/backend | jq -e '.data.current_version >= 2'"

echo "== Rotation: datastore encryption key"
docker exec "$SRV" k3s secrets-encrypt rotate-keys >/dev/null 2>&1
for _ in $(seq 1 24); do docker exec "$SRV" k3s secrets-encrypt status 2>/dev/null | grep -q 'Current Rotation Stage: reencrypt_finished' && break; sleep 5; done
check "key rotation completed (reencrypt_finished)" bash -c "docker exec $SRV k3s secrets-encrypt status 2>/dev/null | grep -q 'reencrypt_finished'"
check "canary readable after key rotation" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-dev get secret phase3-canary -o jsonpath='{.data.v}' | base64 -d) == $canary ]]"
check "ESO Secret readable after key rotation" test -n "$(secret_val demo-dev db_password)"

echo "== OpenBao persistence across restart"
kc -n openbao delete pod openbao-0 >/dev/null; kill $pf 2>/dev/null || true; sleep 5
kc -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=120s >/dev/null
check "restarted pod comes up sealed (manual unseal model)" bash -c \
  "kubectl --context $KUBE_CONTEXT -n openbao exec openbao-0 -- bao status -format=json 2>/dev/null | jq -e .sealed"
check "unseal script recovers it" "$LAB_ROOT/scripts/openbao-bootstrap.sh" --unseal
kc -n openbao port-forward pod/openbao-0 "$PORT:8200" >/dev/null 2>&1 & pf=$!
for _ in $(seq 1 30); do curl -fsS "$ADDR/v1/sys/health" >/dev/null 2>&1 && break; sleep 1; done
check "rotated value survived restart" bash -c \
  "[[ \$(curl -fsS -H 'X-Vault-Token: $OP' $ADDR/v1/kv-dev/data/demo/backend | jq -r .data.data.db_password) == \"\$1\" ]]" _ "$(secret_val demo-dev db_password)"

echo "== Leak checks"
pw=$(secret_val demo-dev db_password)
# Control: ServiceAccount writes are logged at Request level (bodies included),
# so an annotation canary MUST appear — proving the grep can find payloads.
ann_canary="ann-$(openssl rand -hex 12)"
kc -n demo-dev annotate sa demo-backend lab.platform/canary="$ann_canary" >/dev/null
kc -n demo-dev annotate sa demo-backend lab.platform/canary- >/dev/null; sleep 2
check "control: Request-level canary found in K8s audit log" bash -c "docker exec $SRV grep -q -- '$ann_canary' /var/log/kubernetes/audit/audit.log"
check "app password NOT in K8s audit log"   bash -c "! docker exec $SRV grep -qF -- '$pw' /var/log/kubernetes/audit/audit.log"
check "Secret canary NOT in K8s audit log"  bash -c "! docker exec $SRV grep -q -- '$canary' /var/log/kubernetes/audit/audit.log"
check "app password NOT in OpenBao audit log (HMAC'd)" bash -c "! kubectl --context $KUBE_CONTEXT -n openbao logs openbao-0 --all-containers | grep -qF -- '$pw'"
check "OpenBao audit log records reads"     bash -c "kubectl --context $KUBE_CONTEXT -n openbao logs openbao-0 | grep -q 'kv-dev/data/demo/backend'"
check "app password NOT in repo or reports" bash -c "! grep -rqF -- '$pw' --exclude-dir=.tools --exclude-dir=.git $LAB_ROOT"

summary
