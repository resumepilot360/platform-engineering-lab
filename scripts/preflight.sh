#!/usr/bin/env bash
# Read-only checks before creating or changing the lab.
source "$(dirname "$0")/lib.sh"

ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

echo "Preflight: tools"
check "docker daemon reachable" docker info
check "k3d >= $K3D_MIN_VERSION" ver_ge "$(k3d version | awk '/k3d version/{print $3}')" "$K3D_MIN_VERSION"
check "kubectl client == $KUBECTL_VERSION" test "$(kubectl version --client -o json | jq -r .clientVersion.gitVersion)" = "$KUBECTL_VERSION"
check "helm installed" helm version
check "cilium-cli >= $CILIUM_CLI_MIN_VERSION" ver_ge "$(cilium version --client | awk '{print $2}' | head -1)" "$CILIUM_CLI_MIN_VERSION"
for t in k9s jq yq kubeconform; do check "$t installed" command -v "$t"; done

echo "Preflight: Docker resources"
cpus=$(docker info --format '{{.NCPU}}'); mem_gib=$(( $(docker info --format '{{.MemTotal}}') / 1024**3 ))
check "Docker CPUs >= 4 (have $cpus)" test "$cpus" -ge 4
check "Docker memory >= 8 GiB (have $mem_gib)" test "$mem_gib" -ge 8
free_gib=$(df -g / | awk 'NR==2{print $4}')
check "host disk free >= 20 GiB (have $free_gib)" test "$free_gib" -ge 20

echo "Preflight: host ports"
port_ok() { # free, or already held by our own k3d containers
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  docker ps --format '{{.Names}} {{.Ports}}' | grep -E "^(k3d-$CLUSTER_NAME-serverlb|$REGISTRY_CONTAINER|k3d-mirror-[a-z]+\.localhost) .*:$1->" >/dev/null
}
mirror_ports=$(for m in $MIRRORS; do echo "${m##*|}"; done)
for p in "$API_PORT" "$INGRESS_HTTP_PORT" "$INGRESS_HTTPS_PORT" "$REGISTRY_PORT" $mirror_ports; do
  check "port $p free or owned by lab" port_ok "$p"
done

echo "Preflight: other clusters"
running_other=$(k3d cluster list -o json | jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name!=$n and .serversRunning>0) | .name')
[[ -n "$running_other" ]] && warn "Other k3d clusters running (consume RAM): $running_other"

summary
