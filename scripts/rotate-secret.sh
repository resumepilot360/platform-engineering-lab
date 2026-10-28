#!/usr/bin/env bash
# Rotate one generated field of demo/backend in an environment's KV mount.
#
#   scripts/rotate-secret.sh <dev|staging|prod> [field]   (default field: db_password)
#
# Writes a new KV version with the operator token (never root). ESO picks it up
# within the ExternalSecret refreshInterval (1m). Pods reading the Secret as env
# vars need a restart; volume-mounted Secrets update in place (kubelet sync ~1m).
# The previous version stays in KV history for rollback: see docs/runbooks/secrets.md.
source "$(dirname "$0")/lib.sh"

env="${1:?environment (one of: $ENVIRONMENTS)}"; field="${2:-db_password}"
[[ " $ENVIRONMENTS " == *" $env "* ]] || die "env must be one of: $ENVIRONMENTS"
TOKEN="$(cat "$LAB_ROOT/.tools/secrets/openbao-operator.token")" || die "No operator token; run scripts/openbao-bootstrap.sh"
PORT=18201; ADDR="http://127.0.0.1:$PORT"
kc -n openbao port-forward pod/openbao-0 "$PORT:8200" >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS "$ADDR/v1/sys/health" >/dev/null 2>&1 && break; sleep 1; done

path="kv-$env/data/demo/backend"
current=$(curl -fsS -H "X-Vault-Token: $TOKEN" "$ADDR/v1/$path")
new=$(openssl rand -base64 24)
# Write the full secret: KV v2 writes replace the whole map.
echo "$current" | jq --arg f "$field" --arg v "$new" '{data: (.data.data + {($f): $v}), options: {cas: .data.metadata.version}}' \
  | curl -fsS -X POST -H "X-Vault-Token: $TOKEN" -H 'Content-Type: application/json' --data-binary @- "$ADDR/v1/$path" \
  | jq -r '"[lab] '"$env"' demo/backend '"$field"' rotated -> KV version \(.data.version)"'
