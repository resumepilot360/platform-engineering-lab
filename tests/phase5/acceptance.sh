#!/usr/bin/env bash
# Phase 5 acceptance: supply chain (signatures, SBOM attestations), Kyverno
# enforcement of all nine policies with positive controls, PolicyReports clean,
# Falco runtime detection.
#
# Admission checks use server-side dry-run, which runs the admission webhooks
# without persisting anything. Pod-security style policies are tested in a
# throwaway namespace whose Pod Security level is "privileged", so a denial
# there proves Kyverno (not PSA) blocked it.
source "$(dirname "$0")/../../scripts/lib.sh"
TESTNS=policy-test
IDENT="https://github.com/resumepilot360/platform-engineering-lab/.github/workflows/ci.yaml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"
BUSYBOX="k3d-registry.localhost:5001/lab/busybox:1.37.0"
cleanup() { kc delete ns "$TESTNS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
            kc -n demo-dev delete pod falco-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

pin() { yq ".images[] | select(.name==\"$2\") | .digest" "$LAB_ROOT/gitops/environments/$1/kustomization.yaml"; }
SIGNED="ghcr.io/resumepilot360/demo-backend@$(pin dev demo-backend)"
UNSIGNED="ghcr.io/resumepilot360/demo-backend@sha256:3135a1bedbc6b2475ae8d5e716c5a772b448bd27fc863ba5ca01db76e62d7dbc" # pre-signing build

# pod NAME NS IMAGE [extra JSON merged into the pod spec]
pod() {
  jq -n --arg n "$1" --arg ns "$2" --arg img "$3" --argjson extra "${4:-{\}}" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $n, namespace: $ns, labels: {"app.kubernetes.io/name": $n, "app.kubernetes.io/part-of": "phase5-test"}},
    spec: ({
      automountServiceAccountToken: false,
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "c", image: $img, command: ["sleep", "60"],
        resources: {requests: {cpu: "5m", memory: "8Mi"}, limits: {cpu: "50m", memory: "32Mi"}},
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}}]
    } * $extra)
  }'
}
admitted() { kc apply --dry-run=server -f - >/dev/null 2>&1; }
# denied_by POLICY  (reads manifest on stdin) — must be rejected, and by that policy
denied_by() { local out; out=$(kc apply --dry-run=server -f - 2>&1) && return 1; grep -q "$1" <<<"$out"; }
# admit NAME NS IMAGE [EXTRA] [JQ]       — manifest (optionally reshaped by JQ) is admitted
# deny POLICY NAME NS IMAGE [EXTRA] [JQ] — manifest is rejected by POLICY
admit() { pod "$1" "$2" "$3" "${4:-{\}}" | jq "${5:-.}" | admitted; }
deny()  { local p="$1"; shift; pod "$1" "$2" "$3" "${4:-{\}}" | jq "${5:-.}" | denied_by "$p"; }
ns_denied() { local out; out=$(kc create namespace unlabelled-test --dry-run=server 2>&1) && return 1; grep -q require-labels <<<"$out"; }
TO_DEPLOY='{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:("d-"+.metadata.name),namespace:.metadata.namespace,labels:.metadata.labels},spec:{selector:{matchLabels:{"app.kubernetes.io/name":.metadata.name}},template:{metadata:{labels:.metadata.labels},spec:.spec}}}'
PRIV_C='{"containers":[{"name":"c","image":"'"$BUSYBOX"'","securityContext":{"privileged":true}}]}'


echo "== Supply chain"
for env in dev staging prod; do
  for app in demo-backend demo-frontend; do
    ref="ghcr.io/resumepilot360/$app@$(pin $env $app)"
    check "$env $app signed by ci.yaml@main" cosign verify --certificate-identity "$IDENT" --certificate-oidc-issuer "$ISSUER" "$ref"
    check "$env $app has signed CycloneDX SBOM" cosign verify-attestation --type cyclonedx --certificate-identity "$IDENT" --certificate-oidc-issuer "$ISSUER" "$ref"
  done
done
check "signature from another identity is rejected" bash -c \
  "! cosign verify --certificate-identity https://github.com/attacker/repo/.github/workflows/ci.yaml@refs/heads/main --certificate-oidc-issuer $ISSUER $SIGNED"

echo "== Kyverno health"
check "admission controller available" kc -n kyverno wait --for=condition=Available deploy/kyverno-admission-controller --timeout=60s
check "8 ClusterPolicies Ready" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT get clusterpolicy -o json | jq '[.items[] | select(.status.conditions[]? | .type==\"Ready\" and .status==\"True\")] | length') -eq 8 ]]"
check "ImageValidatingPolicy Ready" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT get imagevalidatingpolicy verify-image-signatures -o jsonpath='{.status.conditionStatus.ready}') == true ]]"
check "every ClusterPolicy rule enforces" bash -c \
  "kubectl --context $KUBE_CONTEXT get clusterpolicy -o json | jq -e '[.items[].spec.rules[].validate.failureAction] | all(. == \"Enforce\")'"
check "ImageValidatingPolicy denies" bash -c \
  "kubectl --context $KUBE_CONTEXT get imagevalidatingpolicy verify-image-signatures -o json | jq -e '.spec.validationActions == [\"Deny\"]'"
check "platform-policies Synced/Healthy (Argo CD owns policies)" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT -n argocd get application platform-policies -o jsonpath='{.status.sync.status}/{.status.health.status}') == Synced/Healthy ]]"

echo "== Enforcement in a PSA-privileged namespace (Kyverno is the only control)"
kc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $TESTNS
  labels: {lab.platform/environment: test, pod-security.kubernetes.io/enforce: privileged}
YAML
check "control: compliant pod admitted"            admit ok "$TESTNS" "$BUSYBOX"
check "privileged container denied"                deny disallow-privileged-containers p "$TESTNS" "$BUSYBOX" "$PRIV_C"
check "running as root denied"                     deny require-run-as-non-root r "$TESTNS" "$BUSYBOX" '{"securityContext":{"runAsNonRoot":false,"runAsUser":0}}'
check "hostNetwork denied"                         deny disallow-host-namespaces h "$TESTNS" "$BUSYBOX" '{"hostNetwork":true}'
check "hostPath volume denied"                     deny disallow-host-path v "$TESTNS" "$BUSYBOX" '{"volumes":[{"name":"h","hostPath":{"path":"/etc"}}]}'
check "namespace without environment label denied" ns_denied

echo "== Enforcement in demo-dev"
check "control: signed image + compliant spec admitted" admit ok demo-dev "$SIGNED"
check "unsigned image denied (pre-signing build)"       deny verify-image-signatures u demo-dev "$UNSIGNED"
check "unapproved registry denied (docker.io)"          deny restrict-image-registries d demo-dev docker.io/library/busybox:1.37.0
check "forbidden ServiceAccount denied (eso-reader)"    deny restrict-service-accounts s demo-dev "$SIGNED" '{"serviceAccountName":"eso-reader"}'
check "missing ownership labels denied"                 deny require-labels l demo-dev "$SIGNED" '{}' 'del(.metadata.labels)'
# LimitRange defaults Pods, so the explicit-limits rule is proven on a Deployment template (autogen).
check "Deployment without requests/limits denied (autogen)" deny require-requests-limits x demo-dev "$SIGNED" '{}' "$TO_DEPLOY | del(.spec.template.spec.containers[0].resources)"
check "control: same Deployment with limits admitted"       admit x demo-dev "$SIGNED" '{}' "$TO_DEPLOY"

echo "== PolicyReports (current pods)"
check "no failing results for running app/platform pods" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT get policyreport -A -o json | jq '[.items[] | select(.scope.kind==\"Pod\") | .results[]? | select(.result==\"fail\")] | length') -eq 0 ]]"

echo "== Falco runtime detection"
check "Falco running on every node" bash -c \
  "[[ \$(kubectl --context $KUBE_CONTEXT -n falco get ds falco -o jsonpath='{.status.numberReady}') -eq \$(kubectl --context $KUBE_CONTEXT get nodes --no-headers | wc -l) ]]"
pod falco-probe demo-dev "$BUSYBOX" | jq '.spec.containers[0].command = ["sleep", "300"]' | kc apply -f - >/dev/null
kc -n demo-dev wait --for=condition=Ready pod/falco-probe --timeout=90s >/dev/null
node=$(kc -n demo-dev get pod falco-probe -o jsonpath='{.spec.nodeName}')
fpod=$(kc -n falco get pods -o wide --no-headers | awk -v n="$node" '$7==n{print $1}')
kc -n demo-dev exec falco-probe -- sh -c 'echo phase5-probe' >/dev/null
alerted() { kc -n falco logs "$fpod" -c falco --since=3m | grep '^{' | jq -e -s \
  'any(.[]; .rule=="Shell in lab application container" and .output_fields["k8s.pod.name"]=="falco-probe" and (.output_fields["proc.cmdline"]|test("phase5-probe")))' >/dev/null; }
for _ in $(seq 1 12); do alerted && break; sleep 5; done
check "shell in app container raises Falco alert with pod context" alerted
check "smoke-test hook pods do not raise the shell alert" bash -c \
  "! kubectl --context $KUBE_CONTEXT -n falco logs -l app.kubernetes.io/name=falco -c falco --since=24h --prefix=false | grep '^{' | jq -e -s 'any(.[]; .rule==\"Shell in lab application container\" and (.output_fields[\"k8s.pod.name\"]|startswith(\"smoke-test-\")) and (.time > \"$(date -u -v-10M +%Y-%m-%dT%H:%M)\"))' >/dev/null"

summary
