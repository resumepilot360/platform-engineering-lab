#!/usr/bin/env bash
# Install pinned CLI tools. kubectl goes to .tools/bin (repo-local, checksum
# verified) so it matches the cluster minor version without replacing the
# system kubectl. Other tools come from Homebrew.
source "$(dirname "$0")/lib.sh"

mkdir -p "$LAB_ROOT/.tools/bin"
if [[ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "$KUBECTL_VERSION" ]]; then
  log "Installing kubectl $KUBECTL_VERSION into .tools/bin"
  base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/darwin/arm64"
  curl -fsSL -o "$LAB_ROOT/.tools/bin/kubectl" "$base/kubectl"
  echo "$(curl -fsSL "$base/kubectl.sha256")  $LAB_ROOT/.tools/bin/kubectl" | shasum -a 256 -c -
  chmod +x "$LAB_ROOT/.tools/bin/kubectl"
fi

for t in k9s cilium-cli yq kubeconform jq helm; do
  bin="$t"; [[ $t == cilium-cli ]] && bin=cilium
  command -v "$bin" >/dev/null || { log "brew install $t"; brew install "$t"; }
done
log "Tools ready"
