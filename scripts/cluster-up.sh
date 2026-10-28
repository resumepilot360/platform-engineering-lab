#!/usr/bin/env bash
# Create (or converge) the platform-lab cluster from version-controlled config.
# Idempotent: safe to re-run. Never touches other k3d clusters.
source "$(dirname "$0")/lib.sh"

"$LAB_ROOT/scripts/preflight.sh" || die "Preflight failed"

if ! registry_exists; then
  log "Creating registry $REGISTRY_CONTAINER on 127.0.0.1:$REGISTRY_PORT"
  k3d registry create "$REGISTRY_NAME" --port "127.0.0.1:$REGISTRY_PORT"
else
  docker start "$REGISTRY_CONTAINER" >/dev/null
fi
"$LAB_ROOT/scripts/seed-registry.sh"

if ! cluster_exists; then
  log "Creating cluster $CLUSTER_NAME"
  k3d cluster create --config "$LAB_ROOT/local/k3d/platform-lab.yaml"
else
  log "Cluster $CLUSTER_NAME exists; starting it"
  k3d cluster start "$CLUSTER_NAME"
fi

log "Installing Cilium $CILIUM_CHART_VERSION"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
hc upgrade --install cilium cilium/cilium --version "$CILIUM_CHART_VERSION" \
  --namespace kube-system -f "$LAB_ROOT/platform/networking/cilium/values.yaml" --wait --timeout 5m
cilium --context "$KUBE_CONTEXT" status --wait --wait-duration 5m >/dev/null

log "Waiting for nodes"
kc wait --for=condition=Ready nodes --all --timeout=180s

log "Applying platform namespaces"
kc apply -k "$LAB_ROOT/platform/namespaces"

log "Waiting for core add-ons"
for d in coredns metrics-server local-path-provisioner; do
  kc -n kube-system rollout status deploy/"$d" --timeout=180s
done
until kc -n kube-system get deploy/traefik >/dev/null 2>&1; do sleep 3; done
kc -n kube-system rollout status deploy/traefik --timeout=300s

"$LAB_ROOT/scripts/health-check.sh"
