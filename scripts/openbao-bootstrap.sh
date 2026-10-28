#!/usr/bin/env bash
# Initialise, unseal, configure and seed OpenBao. Idempotent.
#
#   scripts/openbao-bootstrap.sh              full converge
#   scripts/openbao-bootstrap.sh --unseal     unseal only (after a pod/cluster restart)
#
# All calls go to the HTTP API over a port-forward. Tokens and secret values
# travel only in headers/bodies, never in `kubectl exec` arguments (which the
# Kubernetes audit log records in requestURI).
#
# Local state (gitignored, 0600) in .tools/secrets/:
#   openbao-init.json        unseal keys + root token — the lab's most sensitive file
#   openbao-operator.token   scoped token for seeding/rotation (policy secrets-operator)
source "$(dirname "$0")/lib.sh"

CFG="$LAB_ROOT/platform/secrets/openbao"
SDIR="$LAB_ROOT/.tools/secrets"; mkdir -p "$SDIR"; chmod 700 "$SDIR"
INIT="$SDIR/openbao-init.json"; OPTOKEN="$SDIR/openbao-operator.token"
PORT=18200; ADDR="http://127.0.0.1:$PORT"

kc -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=180s >/dev/null
kc -n openbao port-forward pod/openbao-0 "$PORT:8200" >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS "$ADDR/v1/sys/seal-status" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$ADDR/v1/sys/seal-status" >/dev/null 2>&1 || die "OpenBao API unreachable via port-forward (pod crash-looping? kubectl -n openbao logs openbao-0)"

# api METHOD PATH [JSON-BODY] — uses $TOKEN if set
api() {
  local args=(-fsS -X "$1" "$ADDR/v1/$2")
  [[ -n "${TOKEN:-}" ]] && args+=(-H "X-Vault-Token: $TOKEN")
  [[ $# -ge 3 ]] && args+=(-H 'Content-Type: application/json' --data-binary @-)
  if [[ $# -ge 3 ]]; then printf '%s' "$3" | curl "${args[@]}"; else curl "${args[@]}"; fi
}
status() { api GET sys/seal-status || die "seal-status request failed"; }

# --- init -------------------------------------------------------------------
initialized=$(status | jq -r .initialized)
[[ "$initialized" =~ ^(true|false)$ ]] || die "Unexpected seal-status response"
if [[ "$initialized" == false ]]; then
  [[ -s "$INIT" ]] && die "OpenBao is uninitialised but $INIT exists — refusing to overwrite old keys. Move it aside if the data is really gone."
  log "Initialising OpenBao (Shamir 3 shares, threshold 2)"
  # Write to a temp file and only move it into place once it holds valid key material.
  tmp=$(mktemp "$SDIR/.init.XXXXXX")
  api PUT sys/init '{"secret_shares":3,"secret_threshold":2}' > "$tmp" \
    && jq -e '(.keys_base64 | length) == 3 and (.root_token | length) > 0' "$tmp" >/dev/null \
    || { rm -f "$tmp"; die "Initialisation failed or returned no keys"; }
  chmod 600 "$tmp"; mv "$tmp" "$INIT"
fi
[[ -s "$INIT" ]] || die "OpenBao is initialised but $INIT is missing — unseal keys are lost; see docs/runbooks/secrets.md"

# --- unseal -----------------------------------------------------------------
if [[ "$(status | jq -r .sealed)" == true ]]; then
  log "Unsealing"
  for i in 0 1; do
    api PUT sys/unseal "$(jq -c --argjson i $i '{key: .keys_base64[$i]}' "$INIT")" >/dev/null
  done
fi
[[ "$(status | jq -r .sealed)" == false ]] || die "Still sealed"
kc -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=60s >/dev/null
[[ "${1:-}" == "--unseal" ]] && { log "Unsealed"; exit 0; }

# --- configure (root token) ---------------------------------------------------
TOKEN="$(jq -r .root_token "$INIT")"

# The audit device is declared in the server config (values.yaml); verify it is active.
api GET sys/audit | jq -e '.data["stdout/"]' >/dev/null || die "Audit device stdout/ not active — check the audit stanza in platform/secrets/openbao/values.yaml"

for env in dev staging; do
  api GET sys/mounts | jq -e --arg m "kv-$env/" '.data[$m]' >/dev/null || {
    log "Enabling KV v2 mount kv-$env/"
    api POST "sys/mounts/kv-$env" '{"type":"kv","options":{"version":"2"}}' >/dev/null; }
done

api GET sys/auth | jq -e '.data["kubernetes/"]' >/dev/null || {
  log "Enabling Kubernetes auth"
  api POST sys/auth/kubernetes '{"type":"kubernetes"}' >/dev/null; }
# In-cluster: OpenBao uses its own ServiceAccount token + CA for TokenReview.
api POST auth/kubernetes/config '{"kubernetes_host":"https://kubernetes.default.svc:443"}' >/dev/null

for f in "$CFG"/policies/*.hcl; do
  name="$(basename "$f" .hcl)"
  api PUT "sys/policies/acl/$name" "$(jq -Rs '{policy: .}' "$f")" >/dev/null
done
for f in "$CFG"/roles/*.json; do
  api POST "auth/kubernetes/role/$(basename "$f" .json)" "$(jq -c . "$f")" >/dev/null
done
log "Policies: $(api LIST sys/policies/acl | jq -r '.data.keys | join(",")')"
log "Roles:    $(api LIST auth/kubernetes/role | jq -r '.data.keys | join(",")')"

# Scoped operator token (renewed on every run) so day-to-day work never uses root.
( umask 077; api POST auth/token/create \
    '{"policies":["secrets-operator"],"ttl":"24h","display_name":"secrets-operator","no_parent":true}' \
  | jq -r .auth.client_token > "$OPTOKEN" )

# --- seed (only if absent; values are generated, never stored in Git) --------
TOKEN="$(cat "$OPTOKEN")"
for env in dev staging; do
  if ! api GET "kv-$env/data/demo/backend" >/dev/null 2>&1; then
    log "Seeding kv-$env/demo/backend with generated values"
    body=$(jq -n --arg u "demo_$env" --arg p "$(openssl rand -base64 24)" --arg k "$(openssl rand -hex 16)" \
      '{data: {db_username: $u, db_password: $p, api_key: $k}}')
    api POST "kv-$env/data/demo/backend" "$body" >/dev/null
  fi
done
log "OpenBao ready"
