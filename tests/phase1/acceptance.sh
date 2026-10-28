#!/usr/bin/env bash
# Phase 1 acceptance tests. Deploys smoke workloads into lab-smoke, verifies
# them, and leaves them running for inspection (remove with --cleanup).
source "$(dirname "$0")/../../scripts/lib.sh"
NS=lab-smoke
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--cleanup" ]]; then kc delete -k "$HERE/manifests" --ignore-not-found; exit 0; fi

echo "== AC1-3: nodes, system pods, API readiness"
"$LAB_ROOT/scripts/health-check.sh" && check "health-check.sh passes" true || check "health-check.sh passes" false

echo "== AC4: test applications deploy"
kc apply -k "$HERE/manifests" >/dev/null
check "whoami rollout complete"        kc -n $NS rollout status deploy/whoami --timeout=120s
check "storage-probe rollout complete" kc -n $NS rollout status deploy/storage-probe --timeout=120s
check "image pulled from local registry" bash -c \
  "kubectl --context $KUBE_CONTEXT -n $NS get pods -l app.kubernetes.io/name=whoami -o jsonpath='{.items[*].status.containerStatuses[*].imageID}' | grep -q '^k3d-registry.localhost:5001/'"
nodes=$(kc -n $NS get pods -l app.kubernetes.io/name=whoami -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')
check "whoami replicas spread over >1 node (got $nodes)" test "$nodes" -gt 1
check "LimitRange/limits present on pods" bash -c \
  "kubectl --context $KUBE_CONTEXT -n $NS get pods -o json | jq -e '[.items[].spec.containers[].resources.limits.memory] | all'"
check "privileged pod rejected by Pod Security (restricted)" bash -c \
  "! kubectl --context $KUBE_CONTEXT -n $NS run psa-test --image=k3d-registry.localhost:5001/lab/busybox:1.37.0 --restart=Never --privileged --dry-run=server -- true"

echo "== AC5: ingress routes traffic"
url="http://smoke.lab.localhost:$INGRESS_HTTP_PORT/"
for _ in $(seq 1 20); do curl -fsS -m 3 "$url" >/dev/null 2>&1 && break; sleep 2; done
check "GET $url returns 200 via Traefik" curl -fsS -m 5 "$url"
check "response comes from a whoami pod" bash -c "curl -fsS -m 5 '$url' | grep -q '^Hostname: whoami-'"
check "unknown host returns 404" bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: nope.lab.localhost' http://127.0.0.1:$INGRESS_HTTP_PORT/) == 404 ]]"
hits=$(for _ in $(seq 1 20); do curl -fsS -m 3 "$url" | awk '/^Hostname:/{print $2}'; done | sort -u | wc -l | tr -d ' ')
check "load balanced across both replicas (saw $hits)" test "$hits" -eq 2

echo "== AC6: persistent storage"
pod() { kc -n $NS get pod -l app.kubernetes.io/name=storage-probe -o jsonpath='{.items[0].metadata.name}'; }
token="probe-$(date +%s)"
p1=$(pod); node1=$(kc -n $NS get pod "$p1" -o jsonpath='{.spec.nodeName}')
check "PVC Bound" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n $NS get pvc storage-probe -o jsonpath='{.status.phase}') == Bound ]]"
check "write to volume" kc -n $NS exec "$p1" -- sh -c "echo $token > /data/token"
kc -n $NS delete pod "$p1" --wait=true >/dev/null
kc -n $NS rollout status deploy/storage-probe --timeout=120s >/dev/null
p2=$(pod); node2=$(kc -n $NS get pod "$p2" -o jsonpath='{.spec.nodeName}')
check "data survives pod replacement ($p1 -> $p2)" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT -n $NS exec $p2 -- cat /data/token) == $token ]]"
check "replacement pinned to same node by PV affinity ($node1)" test "$node1" = "$node2"
check "root filesystem is read-only" bash -c "! kubectl --context $KUBE_CONTEXT -n $NS exec $p2 -- touch /should-fail"

echo "== AC7: reproducible from configuration"
check "static validation passes" "$LAB_ROOT/scripts/validate.sh"

summary
