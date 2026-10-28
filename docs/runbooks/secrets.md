# Runbook: secrets (OpenBao, External Secrets, encryption at rest)

Local state lives in `.tools/secrets/` (gitignored, 0600):
`openbao-init.json` (unseal keys + root token) and `openbao-operator.token` (24h, policy `secrets-operator`).

## Routine

| Task | Command | Expected |
|---|---|---|
| Unseal after a restart | `scripts/openbao-bootstrap.sh --unseal` | `[lab] Unsealed` |
| Full converge (policies, roles, mounts, seed) | `scripts/openbao-bootstrap.sh` | `[lab] OpenBao ready` |
| Rotate an app secret | `scripts/rotate-secret.sh dev db_password` | `rotated -> KV version N`; k8s Secret changes within ~1 min |
| Force an immediate ESO sync | `kubectl -n demo-dev annotate externalsecret demo-backend-db force-sync=$(date +%s) --overwrite` | Secret updated |
| Restart env-var consumers | `kubectl -n demo-dev rollout restart deploy/<app>` | |
| Rotate the datastore encryption key | `docker exec k3d-platform-lab-server-0 k3s secrets-encrypt rotate-keys` then `... status` | `Current Rotation Stage: reencrypt_finished` |
| Check encryption | `docker exec k3d-platform-lab-server-0 k3s secrets-encrypt status` | `Encryption Status: Enabled`, `Active Key Type: SecretBox` |
| Phase 3 tests | `tests/phase3/acceptance.sh` | all PASS |

## Rollback an app secret to the previous version
```bash
kubectl --context k3d-platform-lab -n openbao port-forward pod/openbao-0 18200:8200 &
T=$(cat .tools/secrets/openbao-operator.token); A=http://127.0.0.1:18200/v1
curl -s -H "X-Vault-Token: $T" "$A/kv-dev/metadata/demo/backend" | jq .data.current_version   # e.g. 3
curl -s -H "X-Vault-Token: $T" "$A/kv-dev/data/demo/backend?version=2" \
  | jq '{data: .data.data}' | curl -s -X POST -H "X-Vault-Token: $T" --data-binary @- "$A/kv-dev/data/demo/backend"
kill %1
```
The restored value becomes a new version (4). History is preserved.

## Troubleshooting

### ExternalSecret `SecretSyncedError` / SecretStore not Ready
Evidence: `kubectl -n demo-dev describe externalsecret demo-backend-db` and `kubectl -n external-secrets logs deploy/external-secrets`.

| Message contains | Cause | Fix |
|---|---|---|
| `connection refused` / `no endpoints` | OpenBao sealed (its pod is NotReady while sealed) or down | `scripts/openbao-bootstrap.sh --unseal` |
| `permission denied` (403) on login | SA, namespace or audience doesn't match the role | Compare the SecretStore `serviceAccountRef` / `audiences` with `platform/secrets/openbao/roles/*.json` |
| `permission denied` on read | Policy doesn't cover the path (e.g. dev store asking for staging) | Expected if cross-environment. Otherwise fix `policies/*.hcl` and re-run the bootstrap |
| `secret not found` | Key not seeded | `scripts/openbao-bootstrap.sh` seeds missing keys |

### Lost `openbao-init.json`
Without 2 of 3 unseal keys the data **can't be recovered**; that is the point of
the barrier. Recovery in the lab: delete the PVC `data-openbao-0` (destroys all
OpenBao data), move the old init file aside, and re-run
`scripts/openbao-bootstrap.sh`. It re-initialises and re-seeds generated values.
All consumers then get new secrets. On AWS this failure mode doesn't exist for
Secrets Manager. The equivalent catastrophe is deleting the KMS key, which is why
`ScheduleKeyDeletion` is alerted on and has a 30-day waiting period.

### Bootstrap refuses: "uninitialised but openbao-init.json exists"
OpenBao lost its storage (PVC recreated) but old keys exist. The script won't
overwrite them, in case the PVC comes back. Move the file aside deliberately to proceed.

### Suspected secret leak
1. Rotate it immediately (`rotate-secret.sh`), then restart its consumers.
2. Find who read it: `kubectl -n openbao logs openbao-0 | jq -c 'select(.request.path=="kv-dev/data/demo/backend") | {time, auth: .auth.metadata, remote: .request.remote_address}'`
   (Values are HMAC'd. Compute a value's HMAC with `POST sys/audit-hash/stdout` and search for it.)
3. Find who read the Kubernetes Secret: the K8s audit log, `objectRef.resource=="secrets"`, `objectRef.name=="demo-backend-db"`.
