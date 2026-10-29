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

for m in $MIRRORS; do
  IFS='|' read -r name upstream port <<<"$m"
  if ! registry_exists "k3d-$name"; then
    log "Creating pull-through cache k3d-$name -> $upstream (127.0.0.1:$port)"
    k3d registry create "$name" --port "127.0.0.1:$port" --proxy-remote-url "$upstream" \
      -v "k3d-$name-data:/var/lib/registry" >/dev/null
  else
    docker start "k3d-$name" >/dev/null
  fi
done

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
  --namespace kube-system -f "$LAB_ROOT/platform/networking/cilium/values.yaml" --wait --timeout 15m
cilium --context "$KUBE_CONTEXT" status --wait --wait-duration 5m >/dev/null

log "Waiting for nodes"
kc wait --for=condition=Ready nodes --all --timeout=180s

log "Applying bootstrap namespaces"
kc apply -k "$LAB_ROOT/local/bootstrap"

log "Installing External Secrets Operator $EXTERNAL_SECRETS_CHART_VERSION and OpenBao $OPENBAO_CHART_VERSION"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo update external-secrets openbao >/dev/null
hc upgrade --install external-secrets external-secrets/external-secrets --version "$EXTERNAL_SECRETS_CHART_VERSION" \
  --namespace external-secrets -f "$LAB_ROOT/platform/secrets/external-secrets/values.yaml" --wait --timeout 15m
# No --wait: the OpenBao pod only becomes Ready once unsealed by the bootstrap.
hc upgrade --install openbao openbao/openbao --version "$OPENBAO_CHART_VERSION" \
  --namespace openbao -f "$LAB_ROOT/platform/secrets/openbao/values.yaml"
"$LAB_ROOT/scripts/openbao-bootstrap.sh"

log "Installing Kyverno $KYVERNO_CHART_VERSION and Falco $FALCO_CHART_VERSION"
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update kyverno falcosecurity >/dev/null
hc upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno -f "$LAB_ROOT/platform/policies/kyverno/values.yaml" --wait --timeout 15m
hc upgrade --install falco falcosecurity/falco --version "$FALCO_CHART_VERSION" \
  --namespace falco -f "$LAB_ROOT/platform/runtime/falco/values.yaml" --wait --timeout 15m

# From here on, Argo CD owns all platform config and apps (ADR-0009).
log "Installing Argo CD $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
hc upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd -f "$LAB_ROOT/gitops/bootstrap/argocd/values.yaml" --wait --timeout 15m
kc apply -f "$LAB_ROOT/gitops/bootstrap/root.yaml"
log "Waiting for Argo CD to sync platform applications"
for a in platform-namespaces platform-rbac platform-secret-stores lab-portal; do
  until kc -n argocd get application "$a" >/dev/null 2>&1; do sleep 3; done
  kc -n argocd wait application "$a" --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
  kc -n argocd wait application "$a" --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
done

log "Waiting for core add-ons"
for d in coredns metrics-server local-path-provisioner; do
  kc -n kube-system rollout status deploy/"$d" --timeout=180s
done
until kc -n kube-system get deploy/traefik >/dev/null 2>&1; do sleep 3; done
kc -n kube-system rollout status deploy/traefik --timeout=300s

"$LAB_ROOT/scripts/health-check.sh"
