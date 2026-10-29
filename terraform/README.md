# Terraform: AWS (EKS) implementation of the lab

> **Not deployed.** Nothing here has been applied, and no AWS resources exist.
> CI runs only offline checks (`fmt`, `validate`, Trivy) until the AWS phase is
> approved and the role ARNs are set as repository variables.
> Design: [docs/aws-architecture.md](../docs/aws-architecture.md).

## Layout

```
terraform/
├── bootstrap/                 # once per account, by a human admin (local state first)
│   └── state bucket + KMS · GitHub OIDC provider · ci-ecr-push / tf-plan / tf-apply roles · permissions boundary
├── environments/
│   ├── dev/                   # 1 NAT, no interface endpoints, Spot t4g.medium
│   └── staging/               # NAT per AZ, all endpoints, On-Demand m7g.large
└── modules/
    ├── environment/           # composition used by dev and staging
    ├── kms-key/               # CMK + explicit key policy + rotation
    ├── network/               # VPC, subnets, NAT, routes, S3 gateway + interface endpoints, flow logs
    ├── eks/                   # cluster, node group, launch template, Terraform-owned add-ons
    ├── eks-access/            # persona roles → access entries (lab:* groups), MFA break-glass
    ├── pod-identity-role/     # role trusted by pods.eks.amazonaws.com + association
    ├── ecr/                   # immutable, scan-on-push, KMS, lifecycle, pull-through cache
    ├── secrets/               # Secrets Manager containers + resource policy (never values)
    ├── observability/         # EventBridge security alerts → encrypted SNS
    ├── github-oidc/           # OIDC trust + least-privilege CI/Terraform roles + boundary
    └── cluster-bootstrap/     # Helm: AWS Load Balancer Controller, Argo CD, root app
```

Pinned versions: Terraform `>= 1.11` (CI uses 1.17.1), `hashicorp/aws ~> 6.71`, `hashicorp/helm ~> 3.3`.
Provider lock files (`.terraform.lock.hcl`) are committed.

## Ownership (ADR-0009)
Terraform owns AWS resources, EKS add-ons, IAM, access entries, Pod Identity
associations and the **day-0 Helm releases** (LBC, Argo CD and the root app).
Everything inside the cluster after that (namespaces, RBAC, policies, External
Secrets, apps) is owned by **Argo CD**. Terraform creates Secrets Manager
**containers only**. Values are never in code, state or outputs.

## Security properties (and where they are enforced)

| Property | Where |
|---|---|
| No static AWS credentials | `github-oidc` (OIDC trust pinned to repo + ref/environment), `eks-access` (SSO-assumed roles), Pod Identity |
| `tf-apply` can't escalate | `github-oidc`: IAM writes only under `/platform-lab/`, `iam:CreateRole` only **with** the workload permissions boundary, `PassRole` only to eks/ec2/flow-logs/pods.eks, explicit deny on its own roles and on the boundary policy |
| `tf-plan` can't read secrets | `github-oidc`: deny `GetSecretValue`/`GetParameter`/`kms:Decrypt` except S3 state decryption |
| Apply requires a human | GitHub environment `production` (required reviewer) + trust condition `environment:production` |
| Cluster admin is not implicit | `bootstrap_cluster_creator_admin_permissions = false`, API-only authentication |
| Break-glass is MFA-gated and alarmed | `eks-access` (MFA ≤ 15 min), `observability` (AssumeRole alert) |
| Encryption everywhere | `kms-key` per purpose: EKS Secrets, EBS, logs/SNS, ECR, Secrets Manager (ViaService-scoped), state |
| Nodes hardened | IMDSv2 only, hop limit 1, encrypted gp3, private subnets, no SSH |
| API not exposed to the internet | private endpoint + optional `/32` allow-list; `0.0.0.0/0` rejected by validation |
| Network egress observable | VPC flow logs (ALL) to KMS-encrypted CloudWatch Logs |
| Wrong-account protection | provider `allowed_account_ids` |

Static checks: `terraform validate` (3 roots) and Trivy (0 findings at MEDIUM+).
The one accepted exception is in [`.trivyignore.yaml`](.trivyignore.yaml), with its reason.

## Apply procedure (when the AWS phase is approved)

1. **Account bootstrap** (admin, once per account):
   ```bash
   cd terraform/bootstrap
   terraform init && terraform plan -out=tfplan   # review
   terraform apply tfplan
   terraform output                               # role ARNs, bucket, boundary
   ```
   Optionally migrate this stack's state into the new bucket (`terraform init -migrate-state`).
2. **GitHub repository variables** (not secrets): `AWS_ACCOUNT_ID`, `AWS_TF_PLAN_ROLE_ARN`,
   `AWS_TF_APPLY_ROLE_ARN`, `TF_STATE_BUCKET`. This enables the plan job.
3. **Environment, stage 1 (infrastructure):** open a PR touching `terraform/`. The plan is posted to the run summary for review.
   Run `terraform` workflow → `environment=dev`, `apply=true` → approve `production` → the reviewed plan is applied.
4. **Environment, stage 2 (Kubernetes bootstrap):** set `enable_cluster_bootstrap = true`, then repeat step 3.
   The Helm provider needs the cluster endpoint, which only exists after stage 1.
5. **Secret values** out of band: `aws secretsmanager put-secret-value --secret-id dev/demo/backend --secret-string file://…`
   (from a workstation via break-glass, never via CI).
6. **Access:** `aws eks update-kubeconfig --name platform-lab-dev --role-arn <persona role>`.

### Still needed before stage 2 is useful
- `gitops/clusters/aws-dev`: an Argo CD app-of-apps overlay for AWS (ECR image
  names, ALB Ingress class, the AWS SecretStore provider). It isn't written yet,
  because it's only meaningful against a real cluster.

## Cost and teardown
Estimate (dev, 24/7): **≈ $235–250 / month**, of which the EKS control plane is $73.
Details and levers: [aws-architecture.md §8](../docs/aws-architecture.md#8-cost-estimate-dev-us-east-1-on-demand-list-prices-verify-in-the-aws-pricing-calculator-before-approval).

Teardown (reverse order; full runbook in [aws-architecture.md §9](../docs/aws-architecture.md#9-teardown-order-phase-8-runbook)):
1. Argo CD: delete the `demo-*` Applications, so the ALBs created by Ingresses are removed by the LBC.
2. Stage 2 off: `enable_cluster_bootstrap = false` → apply (removes Argo CD, LBC).
3. `terraform destroy` the environment (via the apply role, reviewed).
4. KMS keys enter a 30-day pending-deletion window. Cancel with `aws kms cancel-key-deletion` if needed.
5. Bootstrap stack last: empty the state bucket deliberately, then destroy.

## Known gaps
- No S3 access logging on the state bucket (Trivy LOW AWS-0089). Use CloudTrail S3 data events, or add a log bucket.
- An account or organization CloudTrail is assumed (alerting reads its events). It isn't created here.
- IAM Identity Center permission sets live in the management account and are out of scope; personas trust the permission-set role ARNs you supply.
- The node role still carries `AmazonEKS_CNI_Policy` (VPC CNI on the host network). Moving it to a Pod Identity role is a hardening step.
