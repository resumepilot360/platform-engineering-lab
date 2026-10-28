#!/usr/bin/env bash
# Runtime health of the platform-lab cluster. Read-only.
source "$(dirname "$0")/lib.sh"

echo "Cluster health: $KUBE_CONTEXT"
check "API /readyz (host :$API_PORT)" bash -c "kubectl --context $KUBE_CONTEXT get --raw='/readyz' | grep -qx ok"
check "API /livez"                     bash -c "kubectl --context $KUBE_CONTEXT get --raw='/livez' | grep -qx ok"
expected=$((1 + 2))
check "$expected nodes Ready" bash -c "[[ \$(kubectl --context $KUBE_CONTEXT get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type==\"Ready\" and .status==\"True\"))] | length') -eq $expected ]]"
check "Cilium healthy"        cilium --context "$KUBE_CONTEXT" status --wait --wait-duration 60s
for d in coredns metrics-server local-path-provisioner traefik cilium-operator hubble-relay; do
  check "kube-system/$d available" kc -n kube-system wait --for=condition=Available deploy/"$d" --timeout=30s
done
check "no kube-system pods outside Running/Succeeded" bash -c \
  "[[ -z \$(kubectl --context $KUBE_CONTEXT -n kube-system get pods --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null) ]]"
check "metrics API serving (kubectl top nodes)" kc top nodes
check "registry reachable from host" curl -fsS "http://localhost:$REGISTRY_PORT/v2/"
check "audit log being written" docker exec "k3d-$CLUSTER_NAME-server-0" test -s /var/log/kubernetes/audit/audit.log

summary
