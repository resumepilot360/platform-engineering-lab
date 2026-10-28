#!/usr/bin/env bash
# Stop (default) or delete the platform-lab cluster. Never touches dev-cluster.
#   cluster-down.sh            stop containers, keep all state
#   cluster-down.sh --delete   delete the cluster (registry and its images are kept)
source "$(dirname "$0")/lib.sh"

cluster_exists || { log "Cluster $CLUSTER_NAME does not exist"; exit 0; }
case "${1:-}" in
  --delete)
    read -r -p "Delete cluster $CLUSTER_NAME and all its volumes? Type the cluster name: " ans
    [[ "$ans" == "$CLUSTER_NAME" ]] || die "Aborted"
    k3d cluster delete "$CLUSTER_NAME" ;;
  "") k3d cluster stop "$CLUSTER_NAME" ;;
  *)  die "Usage: $0 [--delete]" ;;
esac
