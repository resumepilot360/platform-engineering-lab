# IAM Model

How identity, authentication and authorization work in the local lab, and how
each piece maps to AWS. **Local Kubernetes RBAC does not reproduce AWS IAM.**
It reproduces only the *Kubernetes half* of the EKS model. Everything on the
AWS side (STS, IAM policies, access entries, Pod Identity) is designed in
Phase 8 and is not simulated here.

## 1. Two questions, two systems

| Question | Kubernetes answers with | AWS answers with |
|---|---|---|
| *Who are you?* (authentication) | x509 client cert, ServiceAccount token, OIDC token, webhook | IAM principal (user, role session) proven with SigV4 / STS |
| *What may you do?* (authorization) | RBAC Roles/ClusterRoles bound to users, groups, ServiceAccounts | IAM policies (identity, resource, SCP, permission boundary) |

Kubernetes has **no user database**. A "user" is just a string the
authenticator hands to RBAC. On EKS, the authenticator verifies an IAM
identity, and **access entries** translate it into a Kubernetes username and groups.
RBAC then decides as it does locally.

## 2. Identity types

| Identity | What it is | Local lab | AWS / EKS equivalent |
|---|---|---|---|
| **Human identity** | A person, owned by an IdP (Okta, Entra ID, IAM Identity Center) | Simulated: personas `alice`, `dana`, `riley` with x509 certs signed by the cluster CA (`scripts/issue-user-cert.sh`) | IAM Identity Center user → assumes a permission-set role via SSO |
| **Kubernetes identity** | Username + groups as seen by the API server | Cert `CN` = user, `O` = groups (`lab:platform-admins` …) | Username/groups assigned by an **EKS access entry** mapped from the IAM role ARN |
| **Kubernetes ServiceAccount** | Namespaced workload identity; short-lived projected JWT signed by the API server | `demo-dev/demo-backend` (no permissions), `demo-dev/config-reader` (one ConfigMap) | Same object. Its token is also the trust anchor for IRSA / Pod Identity |
| **GitHub Actions identity** | A workflow run proves itself with a GitHub-issued OIDC token (`repo`, `ref`, `environment` claims) | Not used locally. CI in Phase 4 pushes to Git; **Argo CD** applies inside the cluster, so CI never holds cluster credentials | IAM OIDC provider `token.actions.githubusercontent.com` + role trust policy pinned on `sub` (repo + branch/environment) → STS short-lived credentials. No access keys |
| **AWS IAM role** | Assumable principal with policies; issues temporary STS credentials | None. No AWS calls in local phases | Separate roles: Terraform plan (read-only), Terraform apply (gated), CI image push (ECR only), cluster admin (break-glass), developers |
| **EKS access entries** | EKS API objects mapping an IAM principal ARN → Kubernetes username/groups and/or an EKS access policy | Equivalent to *our cert-issuing step*: deciding which groups an identity gets | `aws_eks_access_entry` + `aws_eks_access_policy_association` in Terraform; replaces the deprecated `aws-auth` ConfigMap |
| **IRSA** | Pod's ServiceAccount token, federated through the cluster's OIDC issuer → `sts:AssumeRoleWithWebIdentity` | Not reproducible (needs a public OIDC issuer trusted by AWS STS) | IAM role trust policy conditioned on `system:serviceaccount:<ns>:<sa>` |
| **EKS Pod Identity** | EKS agent swaps the SA identity for role credentials. The association lives in the EKS API, not the role trust policy | Not reproducible | `aws_eks_pod_identity_association` (ns + SA → role). **Preferred for new workloads**: no per-cluster OIDC provider, reusable trust policy, session tags |

Pod Identity vs IRSA, in short: both give pods AWS credentials scoped to a single
ServiceAccount. IRSA embeds the cluster OIDC issuer in every role trust policy.
Pod Identity keeps the mapping in EKS and uses one trust principal
(`pods.eks.amazonaws.com`). Use IRSA only where Pod Identity is unsupported
(e.g. Fargate, some add-ons).

## 3. Personas and permissions (local)

| Group | Daily permissions | Explicitly denied | Elevation |
|---|---|---|---|
| `lab:platform-admins` | `view` everywhere. Namespaces create/patch (no delete). Nodes cordon/label. Pod delete/evict. Rollout restart and scale | Secrets, RBAC writes, exec, namespace delete | Impersonate exactly `break-glass` / `lab:break-glass` → `cluster-admin` |
| `lab:developers` | `demo-dev`: workloads, services, configmaps, PVCs, ingress, jobs, HPA, exec, port-forward. `demo-staging`: `view` | Secrets, Roles/Bindings, ServiceAccount creation, any write in staging, kube-system | None (staging changes go through GitOps) |
| `lab:auditors` | `view` everywhere + read RBAC, CSRs, admission configs | Secrets, all writes, exec | None |
| `lab:break-glass` | `cluster-admin` | — | Only via impersonation by a platform admin |

Manifests: `platform/rbac/`. Tests: `tests/phase2/acceptance.sh` (55 checks,
run with each persona's own credentials).

### Break-glass: why impersonation
- Daily admin work runs without secrets or RBAC-write access, so a stolen admin cert is less useful.
- Elevation is explicit (`--as=break-glass --as-group=lab:break-glass`).
- The audit log attributes it to the real person: `user.username=alice`, `impersonatedUser.username=break-glass`.
- `resourceNames` pins prevent impersonating anyone else, including `system:masters`. This is tested.
- AWS equivalent: a separate `EKSBreakGlass` IAM role, assumable only with MFA from a small group, mapped by an access entry to `AmazonEKSClusterAdminPolicy`. CloudTrail plus EKS audit logs give attribution.

## 4. Security properties and known limitations

1. **The bootstrap kubeconfig is root.** k3d's admin credential is `system:admin` in
   `system:masters`, a group that **bypasses RBAC** and can't be restricted by
   removing bindings. Use it only for bootstrap (cluster-up, cert issuance).
   On EKS, set `bootstrap_cluster_creator_admin_permissions = false` and grant
   admin explicitly through an access entry.
2. **Client certificates can't be revoked.** Kubernetes has no CRL/OCSP for client
   certs. Mitigations: short TTL (24h, enforced via `expirationSeconds` and tested),
   and access is granted to *groups*, so removing a binding cuts access immediately for every holder.
   Production humans should use OIDC/SSO, not certs.
3. **Pod creation implies ServiceAccount use.** Anyone who can create pods in a
   namespace can run them as *any* ServiceAccount in that namespace. Here,
   `dana` could run a pod as `config-reader`. Least privilege for a ServiceAccount
   is only as strong as the namespace's pod-creation permissions. Phase 5
   (Kyverno) will restrict which ServiceAccounts a workload may use.
4. **The built-in `edit` / `admin` roles can read Secrets.** That's why developers get a custom Role, not `edit`.
5. **Audit gaps on denied impersonation.** The event is attributed to the real
   user with a 403 and `cannot impersonate resource "groups"`, but the
   *attempted* group name is not recorded.
6. **Audit logs are local only.** They stay on server-0 (`/var/log/kubernetes/audit/`)
   and are lost if the cluster is deleted. Phase 7 ships them to Loki. On EKS,
   control-plane `audit` and `authenticator` logs go to CloudWatch Logs.
7. **No anonymous access.** K3s runs with anonymous auth disabled: every
   unauthenticated request, including `/readyz`, returns 401. Tested.

## 5. Local OIDC: deferred

Dex plus kubelogin would demonstrate SSO-style human login with group claims. It
requires a TLS-trusted issuer reachable from both the API server and the
browser, plus a structured `AuthenticationConfiguration` file mounted into
K3s. It is not needed to demonstrate RBAC and is planned as an optional
Phase 2b (decision record 0007).
