#!/usr/bin/env bash
# Phase 2 acceptance: authentication, authorization (RBAC matrix using each
# persona's own credentials), service-account least privilege, break-glass
# elevation, and audit-log evidence.
source "$(dirname "$0")/../../scripts/lib.sh"
ID="$LAB_ROOT/.tools/identities"
API="https://127.0.0.1:$API_PORT"

echo "== Setup: apply RBAC and issue persona certificates (24h)"
kc apply -k "$LAB_ROOT/platform/rbac" >/dev/null
for p in "alice lab:platform-admins" "dana lab:developers" "riley lab:auditors"; do
  # shellcheck disable=SC2086
  "$LAB_ROOT/scripts/issue-user-cert.sh" $p >/dev/null
done
as() { local u="$1"; shift; KUBECONFIG="$ID/$u.kubeconfig" kubectl "$@"; }
can()    { local u="$1"; shift; check "$u CAN    $*" as "$u" auth can-i "$@"; }
cannot() { local u="$1"; shift; check "$u CANNOT $*" bash -c '! KUBECONFIG="$0" kubectl auth can-i "$@"' "$ID/$u.kubeconfig" "$@"; }

echo "== Authentication"
check "no credentials -> 401"   bash -c "[[ \$(curl -sk -o /dev/null -w '%{http_code}' $API/api/v1/namespaces) == 401 ]]"
check "bogus bearer -> 401"     bash -c "[[ \$(curl -sk -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer bogus' $API/api/v1/namespaces) == 401 ]]"
rogue="$(mktemp -d)"; trap 'rm -rf "$rogue"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/CN=mallory/O=system:masters" -keyout "$rogue/k" -out "$rogue/c" 2>/dev/null
check "self-signed cert claiming system:masters -> 401" bash -c \
  "[[ \$(curl -sk -o /dev/null -w '%{http_code}' --cert $rogue/c --key $rogue/k $API/api/v1/namespaces) == 401 ]]"
for p in "alice lab:platform-admins" "dana lab:developers" "riley lab:auditors"; do
  set -- $p
  check "$1 authenticates with groups [$2]" bash -c \
    "KUBECONFIG=$ID/$1.kubeconfig kubectl auth whoami -o json | jq -e '.status.userInfo.username==\"$1\" and (.status.userInfo.groups|index(\"$2\"))'"
done
check "persona certs expire within 25h" bash -c \
  "for u in alice dana riley; do openssl x509 -in $ID/\$u.crt -noout -checkend 90000 >/dev/null && exit 1; done; exit 0"

echo "== Authorization: platform admin (alice)"
can    alice list pods -A
can    alice patch nodes
can    alice create pods --subresource=eviction -n demo-dev
can    alice create namespaces
cannot alice delete namespaces
cannot alice get secrets -n kube-system
cannot alice create clusterrolebindings
cannot alice create pods --subresource=exec -n demo-dev
can    alice impersonate users/break-glass
cannot alice impersonate users/admin
cannot alice impersonate groups/system:masters
check "alice as break-glass CAN get secrets (elevated)" \
  as alice auth can-i get secrets -n kube-system --as=break-glass --as-group=lab:break-glass

echo "== Authorization: developer (dana)"
can    dana create deployments -n demo-dev
can    dana create pods --subresource=exec -n demo-dev
can    dana list pods -n demo-staging
cannot dana create deployments -n demo-staging
cannot dana create pods --subresource=exec -n demo-staging
cannot dana get secrets -n demo-dev
cannot dana create rolebindings -n demo-dev
cannot dana create roles -n demo-dev
cannot dana create serviceaccounts -n demo-dev
cannot dana list pods -n kube-system
cannot dana impersonate users/break-glass

echo "== Authorization: auditor (riley)"
can    riley list pods -A
can    riley list clusterrolebindings
can    riley get roles -n demo-dev
cannot riley get secrets -A
cannot riley delete pods -n demo-dev
cannot riley create pods --subresource=exec -n demo-dev
cannot riley patch deployments -n demo-dev

echo "== Real operations"
check "dana creates + deletes a deployment in demo-dev" bash -c \
  "KUBECONFIG=$ID/dana.kubeconfig kubectl -n demo-dev create deployment rbac-probe --image=k3d-registry.localhost:5001/lab/whoami:v1.11.0 --dry-run=client -o yaml \
   | yq '.spec.template.spec.containers[0].securityContext={\"runAsNonRoot\":true,\"runAsUser\":65532,\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]},\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}' \
   | KUBECONFIG=$ID/dana.kubeconfig kubectl apply -f - && KUBECONFIG=$ID/dana.kubeconfig kubectl -n demo-dev delete deployment rbac-probe"
check "dana denied reading secrets (403)" bash -c \
  "KUBECONFIG=$ID/dana.kubeconfig kubectl -n demo-dev get secrets 2>&1 | grep -q Forbidden"
check "alice break-glass read of kube-system secrets succeeds" \
  as alice -n kube-system get secrets --as=break-glass --as-group=lab:break-glass
# Permitted user (break-glass) + forbidden group: proves the group pin itself.
check "alice cannot add system:masters to break-glass (403)" bash -c \
  "KUBECONFIG=$ID/alice.kubeconfig kubectl get secrets -A --as=break-glass --as-group=system:masters 2>&1 | grep -q 'cannot impersonate resource \"groups\"'"

echo "== Service accounts"
tok=$(kc -n demo-dev create token config-reader --duration=10m)
code() { curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$API$1"; }
check "config-reader GET configmap/app-config -> 200"        test "$(code /api/v1/namespaces/demo-dev/configmaps/app-config)" = 200
check "config-reader GET configmap/kube-root-ca.crt -> 403"  test "$(code /api/v1/namespaces/demo-dev/configmaps/kube-root-ca.crt)" = 403
check "config-reader LIST configmaps -> 403"                 test "$(code /api/v1/namespaces/demo-dev/configmaps)" = 403
check "config-reader LIST secrets -> 403"                    test "$(code /api/v1/namespaces/demo-dev/secrets)" = 403
check "config-reader cross-namespace read -> 403"            test "$(code /api/v1/namespaces/demo-staging/configmaps)" = 403
# Only resource rules count; non-resource discovery URLs and self-reviews are
# granted to every authenticated identity by default (system:basic-user etc).
resource_rules() { # rows of `can-i --list` that name a resource (column 1 non-empty)
  kc auth can-i --list -n demo-dev --as="$1" | awk 'NR>1 && $1 !~ /^\[/ && $1 !~ /^selfsubject/ && substr($0,1,1)!=" "'
}
no_resource_rules() { [[ -z "$(resource_rules "$1")" ]]; }
check "demo-backend has no resource permissions" no_resource_rules system:serviceaccount:demo-dev:demo-backend
check "config-reader has exactly one resource rule" bash -c '[[ $0 -eq 1 ]]' "$(resource_rules system:serviceaccount:demo-dev:config-reader | wc -l | tr -d ' ')"
check "demo-backend token not automounted" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT -n demo-dev get sa demo-backend -o jsonpath='{.automountServiceAccountToken}') == false ]]"

echo "== Audit evidence"
kc create rolebinding audit-probe -n demo-dev --clusterrole=view --user=nobody >/dev/null
kc delete rolebinding audit-probe -n demo-dev >/dev/null
sleep 3
audit="$(mktemp)"; docker exec "k3d-$CLUSTER_NAME-server-0" tail -n 50000 /var/log/kubernetes/audit/audit.log > "$audit"
q() { jq -e -s "$1" "$audit" >/dev/null; }
check "denied secret read by dana recorded (403)" \
  q 'any(.[]; .user.username=="dana" and .objectRef.resource=="secrets" and .responseStatus.code==403)'
check "break-glass use attributed to alice" \
  q 'any(.[]; .user.username=="alice" and .impersonatedUser.username=="break-glass" and .objectRef.resource=="secrets")'
check "secret access logged at Metadata only (no payload)" \
  q '[.[] | select(.objectRef.resource=="secrets")] | length>0 and all(.level=="Metadata" and (has("responseObject")|not))'
check "RBAC change logged with full request body" \
  q 'any(.[]; .objectRef.resource=="rolebindings" and .objectRef.name=="audit-probe" and .verb=="create" and .level=="RequestResponse" and .requestObject.subjects[0].name=="nobody")'
# Denied impersonation is attributed to the real user; the attempted group name
# is not recorded (only "cannot impersonate resource groups") — see iam-model.md.
check "failed group impersonation recorded against alice" \
  q 'any(.[]; .user.username=="alice" and .responseStatus.code==403 and (.responseStatus.message // "" | test("cannot impersonate resource \"groups\"")))'
check "failed authentication recorded (401)" \
  q 'any(.[]; .responseStatus.code==401)'
rm -f "$audit"

summary
