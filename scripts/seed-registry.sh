#!/usr/bin/env bash
# Mirror pinned upstream images into the local registry so workloads pull from
# an approved, local source (and Phase 5 can enforce a registry allow-list).
source "$(dirname "$0")/lib.sh"

registry_exists || die "Registry $REGISTRY_CONTAINER not found; run scripts/cluster-up.sh"
for src in "$WHOAMI_IMAGE" "$BUSYBOX_IMAGE"; do
  name_tag="${src##*/}"                      # whoami:v1.11.0
  dst="localhost:$REGISTRY_PORT/lab/$name_tag"
  log "Mirroring $src -> $dst"
  docker pull -q --platform linux/arm64 "$src" >/dev/null
  docker tag "$src" "$dst"
  docker push -q "$dst" >/dev/null
done
log "Registry catalog: $(curl -fsS "http://localhost:$REGISTRY_PORT/v2/_catalog")"
