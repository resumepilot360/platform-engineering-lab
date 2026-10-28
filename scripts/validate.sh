#!/usr/bin/env bash
# Static validation of all Kustomize/YAML in the repo. No cluster needed;
# add --server to also run a server-side dry-run against platform-lab.
source "$(dirname "$0")/lib.sh"

# Schemas are published per minor version (x.y.0); a missing schema is an error,
# not a skip, so nothing passes unvalidated.
K8S_SCHEMA_VERSION="$(echo "${KUBECTL_VERSION#v}" | cut -d. -f1,2).0"
KC_FLAGS=(-strict -summary -kubernetes-version "$K8S_SCHEMA_VERSION"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

echo "YAML syntax"
while IFS= read -r f; do
  check "parse $f" yq eval-all 'true' "$f"
done < <(git -C "$LAB_ROOT" ls-files --cached --others --exclude-standard '*.yaml' '*.yml')

echo "Kustomize build + schema"
while IFS= read -r k; do
  dir="$(dirname "$k")"
  check "kustomize+kubeconform ${dir#$LAB_ROOT/}" bash -c "kubectl kustomize '$dir' | kubeconform ${KC_FLAGS[*]@Q} -"
  if [[ "${1:-}" == "--server" ]]; then
    check "server dry-run ${dir#$LAB_ROOT/}" kc apply --dry-run=server -k "$dir"
  fi
done < <(find "$LAB_ROOT" -name kustomization.yaml -not -path '*/.tools/*' | sort)

echo "Standalone manifests"
for f in local/configuration/traefik-config.yaml; do
  check "kubeconform $f" kubeconform "${KC_FLAGS[@]}" "$LAB_ROOT/$f"
done
check "k3d config schema" k3d config migrate "$LAB_ROOT/local/k3d/platform-lab.yaml" /dev/null

summary
