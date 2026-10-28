# Secrets Model

How secrets are created, stored, delivered, restricted, rotated and audited,
locally and on AWS. Rule zero: **no real secret value ever exists in Git,
image layers, Terraform source/state/outputs, CI logs, or kubectl/exec command
lines.**

## 1. Flow

```
 operator / automation               OpenBao (openbao ns)                 app namespace (demo-dev)
 ─────────────────────               ───────────────────────              ──────────────────────────────
 rotate-secret.sh ──HTTP API──▶  kv-dev/demo/backend (KV v2, versioned)
   (operator token,                     ▲  policy demo-dev-read
    scoped policy)                      │  role eso-demo-dev
                                        │  (SA eso-reader@demo-dev, aud=openbao, 15m TTL)
                         ESO controller ┴─ login with SA token ◀── SecretStore "openbao"
                         (external-secrets ns)                     ExternalSecret "demo-backend-db"
                                        └─ writes ──────────────▶ Secret "demo-backend-db"
                                                                   (encrypted at rest: secretbox)
                                                                         │ env / volume
                                                                         ▼
                                                                       Pod
```

| Layer | Local | AWS |
|---|---|---|
| Source of truth | OpenBao KV v2, one mount per environment (`kv-dev/`, `kv-staging/`) | AWS Secrets Manager, one account (or path prefix + KMS key) per environment |
| Encryption of source | OpenBao barrier key, protected by Shamir unseal keys (3 shares / threshold 2) | Secrets Manager envelope encryption with a customer-managed **KMS key** per environment |
| Unseal / key custody | Manual unseal from `.tools/secrets/openbao-init.json` | No unseal step. KMS holds the key in HSMs; the key policy controls use |
| Workload → store auth | Kubernetes auth: projected SA token, audience `openbao`, bound to one SA in one namespace | **EKS Pod Identity**: ESO's SA mapped to an IAM role whose policy allows `secretsmanager:GetSecretValue` on `arn:…:secret:dev/demo/*` and `kms:Decrypt` on the dev key only |
| Sync into cluster | External Secrets Operator v2.14, namespaced `SecretStore` | Same ESO manifests. Only `spec.provider` changes (`aws: {service: SecretsManager, region, auth: {jwt: …}}`) |
| Kubernetes Secret at rest | K3s `--secrets-encryption` with **secretbox** (key on the server's disk) | EKS envelope encryption with a KMS key (on by default for new clusters; use a customer-managed key) |
| Audit | OpenBao audit device (stdout, values HMAC'd) + K8s audit log (Secrets at Metadata level) | CloudTrail (`GetSecretValue`, `Decrypt` with principal and session tags) + EKS audit logs to CloudWatch |
| Rotation | `rotate-secret.sh` writes a new KV version; ESO syncs within 1 min | Secrets Manager rotation Lambda (or managed rotation for RDS) on a schedule; ESO `refreshInterval` |

## 2. Environment separation

Isolation is enforced at four independent layers, and every one is tested in
`tests/phase3/acceptance.sh`:

1. **Storage:** dev and staging values live in separate KV mounts (AWS: separate secrets, KMS keys, ideally separate accounts).
2. **OpenBao policy:** `demo-dev-read` grants `read` on `kv-dev/data/demo/*` only. No list, no staging.
3. **OpenBao role binding:** `eso-demo-dev` accepts only SA `eso-reader` in namespace `demo-dev`, and only tokens minted for audience `openbao`. A plain API-server token, another namespace's SA, or another SA in the same namespace is rejected.
4. **Kubernetes RBAC:** developers can't read Secrets or create SecretStores. Only break-glass can create ClusterSecretStores.

## 3. Rotation procedures

| What | How | Propagation | Rollback |
|---|---|---|---|
| App secret (e.g. DB password) | `scripts/rotate-secret.sh dev db_password` (CAS-protected write of a new KV version) | ESO refresh ≤ 1 min. Volume-mounted Secrets update in place (~1 min kubelet sync). **Env-var consumers need `kubectl rollout restart`** | Write the previous version back: `GET kv-dev/data/demo/backend?version=N`, then POST it (runbook) |
| Datastore encryption key | `docker exec k3d-platform-lab-server-0 k3s secrets-encrypt rotate-keys` | Immediate. All Secrets re-encrypted (`reencrypt_finished`) | Old keys remain in the config until the next rotation |
| OpenBao operator token | Re-run `scripts/openbao-bootstrap.sh` (issues a new 24h token) | Immediate | Revoke the old token: `POST auth/token/revoke` |
| ESO → OpenBao tokens | Automatic: 15m TTL, re-login with a fresh SA token | — | — |
| OpenBao unseal keys | `bao operator rekey` (not automated; needs 2 of 3 shares) | — | — |
| Persona certs (Phase 2) | Re-issue. 24h TTL | — | Delete the group binding |

A real DB credential rotation must also change the password in the database.
The two-phase pattern is: create the new credential, publish it, let consumers
move, then revoke the old one. On AWS, the Secrets Manager rotation Lambda's
four steps (`createSecret` / `setSecret` / `testSecret` / `finishSecret`)
encode this. OpenBao's database secrets engine (dynamic, per-lease
credentials) is the stronger option and a candidate for later work.

## 4. Limitations of the local implementation

1. **The encryption key sits next to the data.** K3s stores the secretbox key in
   `/var/lib/rancher/k3s/server/cred/encryption-config.json` on the same disk as
   the datastore. Encryption at rest protects against copying the DB file alone,
   not against someone with root on the server node. KMS fixes this on AWS: the
   key never leaves KMS, and every decrypt is an authorised, logged API call.
2. **Unseal keys and the root token live in a single local file.** That breaks
   key-share separation (production gives shares to different people, or uses
   KMS auto-unseal) and makes `.tools/secrets/openbao-init.json` the lab's most
   sensitive file. The root token is not revoked, so the bootstrap can be re-run.
   Production would revoke it after setup and generate a new one only with a quorum of unseal shares.
3. **OpenBao has no TLS in the cluster** (`tls_disable`). The traffic from ESO
   and port-forwards is plaintext on the pod network. Phase 6 limits who can reach
   port 8200. On AWS, Secrets Manager is TLS-only via a VPC interface endpoint.
4. **A Kubernetes Secret is only as private as its namespace.** Anyone who can
   create pods in `demo-dev` can mount `demo-backend-db` and read it, despite
   RBAC denying `get secrets`. The real boundary is pod-creation rights.
   Phase 5 policies narrow which workloads may mount which Secrets.
5. **Single OpenBao node.** No HA. A restart leaves it sealed until
   `openbao-bootstrap.sh --unseal` runs, and ESO keeps the last synced Secret
   in the meantime, so running apps are unaffected.
6. **The secretbox provider is marked experimental in K3s.** It was chosen over
   the stable default `aescbc` because upstream Kubernetes advises against
   AES-CBC (unauthenticated, padding-oracle risk).

## 5. AWS design (implemented in Phase 8, not created now)

- **KMS:** one customer-managed key per environment (`alias/lab-dev-secrets`,
  `alias/lab-staging-secrets`) with key rotation on. The key policy allows
  administration by the Terraform role and use (`Decrypt`, `GenerateDataKey`)
  only by that environment's ESO role, via `kms:ViaService = secretsmanager.<region>.amazonaws.com`.
  A separate key is used for EKS Secret envelope encryption.
- **Secrets Manager:** secret names like `dev/demo/backend`, tagged `environment=dev`,
  encrypted with the dev key. Resource policy denies access unless
  `aws:PrincipalTag/environment` matches.
- **Terraform owns the secret containers, not their values.** Terraform
  creates `aws_secretsmanager_secret` (name, KMS key, policy, rotation config)
  but **never** `aws_secretsmanager_secret_version` with a real value, because
  values would land in state. Values are set out of band, or generated by the
  rotation Lambda or `manage_master_user_password` for RDS.
- **ESO on EKS:** installed by Argo CD. Its SA gets a Pod Identity association
  to role `eso-dev` (policy scoped to `dev/*` plus the dev key).
  `SecretStore` manifests are identical apart from `provider`.
- **CI:** GitHub Actions never reads app secrets. It builds and pushes images
  via OIDC → `ci-ecr-push` role. Deployment secrets are delivered in-cluster by ESO.
- **Detection:** CloudTrail plus an EventBridge rule alerting on
  `GetSecretValue` from unexpected principals, and on `ScheduleKeyDeletion` or `DisableKey`.

Cost (us-east-1, list price): ~$0.40 per secret per month, $0.05 per 10k API calls,
$1 per KMS key per month, $0.03 per 10k KMS requests. A handful of secrets and 3 keys come to about $5 a month.
