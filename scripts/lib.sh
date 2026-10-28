#!/usr/bin/env bash
# Shared helpers for lab scripts. Source, don't execute.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_ROOT
# shellcheck source=../local/versions.env
source "$LAB_ROOT/local/versions.env"

# Prefer the version-matched kubectl in .tools/bin (see scripts/install-tools.sh).
export PATH="$LAB_ROOT/.tools/bin:$PATH"

if [[ -t 1 ]]; then C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_0=$'\e[0m'; else C_G=; C_R=; C_Y=; C_0=; fi
log()  { printf '%s[lab]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# Every kubectl/helm call is pinned to the lab context so a stray current-context
# (e.g. k3d-dev-cluster) is never modified by these scripts.
kc()   { kubectl --context "$KUBE_CONTEXT" "$@"; }
hc()   { helm --kube-context "$KUBE_CONTEXT" "$@"; }

cluster_exists()  { k3d cluster list -o json | jq -e --arg n "$CLUSTER_NAME" '.[] | select(.name==$n)' >/dev/null; }
registry_exists() { docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; }

# Simple pass/fail accounting for test scripts.
PASS=0; FAIL=0; RESULTS=()
check() { # check "description" command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); RESULTS+=("PASS  $desc"); printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$desc"
  else FAIL=$((FAIL+1)); RESULTS+=("FAIL  $desc"); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$desc"; fi
}
summary() { printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [[ $FAIL -eq 0 ]]; }
