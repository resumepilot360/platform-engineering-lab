# AWS Architecture (EKS): design for Phase 8

> **Status: design only.** No AWS resources exist. Nothing is created until the
> AWS phase is explicitly approved. Terraform modules (`terraform/`) implement
> this design in Phase 8, and every `apply` goes through a reviewed plan.

The same platform as the [local lab](architecture.md), mapped to managed AWS services.
Kubernetes-level components (Argo CD, External Secrets, Kyverno, and the demo app
manifests) are **identical**. What changes is identity, networking, storage of
secrets and keys, ingress, and logging.

## 1. Components

```mermaid
flowchart LR
  subgraph GH["GitHub: resumepilot360/platform-engineering-lab"]
    direction TB
    REPO[("Git repo, main<br/>app + platform + terraform/")]
    ACT["GitHub Actions<br/>ci · promote · terraform-plan · terraform-apply"]
  end

  subgraph AWS["AWS account per environment (dev, staging) · us-east-1"]
    direction TB
    subgraph IDN["Identity"]
      IDC["IAM Identity Center<br/>SSO users → permission sets"]
      OIDC["IAM OIDC provider<br/>token.actions.githubusercontent.com"]
      ROLES["IAM roles<br/>tf-plan · tf-apply · ci-ecr-push<br/>eks-admin · eks-developer · eks-readonly · break-glass"]
    end
    subgraph DATA["Regional services (reached via VPC endpoints)"]
      ECR[("ECR<br/>immutable tags · scan on push<br/>pull-through cache: ghcr/quay/docker")]
      SM[("Secrets Manager<br/>dev/demo/backend …")]
      KMS["KMS CMKs<br/>eks-secrets · secrets-ENV · logs · ecr"]
      CW["CloudWatch Logs + Metrics<br/>EKS control-plane logs · Container Insights"]
      TFS[("S3 Terraform state<br/>versioned · KMS · native lockfile")]
    end
    subgraph EDGE["Edge"]
      R53["Route 53<br/>demo.dev.example.com"]
      ACM["ACM certificate"]
      WAF["AWS WAF (optional)"]
    end
    subgraph VPC["VPC 10.20.0.0/16 · 3 AZs"]
      direction TB
      ALB["Application Load Balancer<br/>public subnets · HTTPS :443"]
      NAT["NAT gateway(s)<br/>public subnets"]
      subgraph EKS["EKS 1.35 (managed control plane, private + restricted public endpoint)"]
        direction TB
        NODES["Managed node group<br/>Graviton t4g/m7g · private subnets<br/>Bottlerocket or AL2023"]
        subgraph ADDONS["EKS add-ons (Terraform-owned)"]
          VPCCNI["VPC CNI<br/>+ NetworkPolicy agent"]
          CORE["CoreDNS · kube-proxy"]
          PIA["Pod Identity agent"]
          EBS["EBS CSI driver (gp3, KMS)"]
          LBC["AWS Load Balancer Controller"]
        end
        subgraph GITOPS["Argo CD-owned (same manifests as local)"]
          ACD["Argo CD"]
          ESO["External Secrets Operator"]
          KYV["Kyverno"]
          APP["demo-frontend → demo-backend<br/>namespaces demo-ENV"]
        end
      end
      VPCE["Interface/Gateway endpoints<br/>ECR api+dkr · S3 · STS · Secrets Manager · KMS · Logs · EKS Auth"]
    end
    GD["GuardDuty EKS Runtime + Audit monitoring<br/>(managed alternative to Falco)"]
    CT["CloudTrail (org/account)"]
  end

  USER(["Engineer"]) -- "SSO login" --> IDC
  IDC -- "assume role" --> ROLES
  ROLES -- "EKS access entry" --> EKS
  INTERNET(["Users"]) --> R53 --> WAF --> ALB
  ACM -.-> ALB
  ALB --> APP
  REPO -- "pull (HTTPS)" --> ACD
  ACT -- "OIDC → STS" --> OIDC
  OIDC --> ROLES
  ACT -- "push signed image" --> ECR
  ACT -- "terraform plan/apply" --> TFS
  NODES -- "pull via endpoint" --> ECR
  ESO -- "Pod Identity → GetSecretValue" --> SM
  SM -. "envelope encryption" .-> KMS
  EKS -. "Secret envelope encryption" .-> KMS
  EKS -- "api, audit, authenticator logs" --> CW
  NODES --> VPCE
  NODES -- "egress for non-endpoint traffic" --> NAT
  LBC -- "provisions" --> ALB
```

## 2. Network and routing

```mermaid
flowchart TB
  IGW["Internet gateway"]
  subgraph VPC["VPC 10.20.0.0/16"]
    direction TB
    subgraph AZA["AZ a"]
      PUBA["public 10.20.0.0/22<br/>ALB, NAT gw"]
      PRIA["private 10.20.32.0/19<br/>nodes + pods (VPC CNI IPs)"]
    end
    subgraph AZB["AZ b"]
      PUBB["public 10.20.4.0/22<br/>ALB"]
      PRIB["private 10.20.64.0/19<br/>nodes + pods"]
    end
    subgraph AZC["AZ c"]
      PUBC["public 10.20.8.0/22<br/>ALB"]
      PRIC["private 10.20.96.0/19<br/>nodes + pods"]
    end
    RTPUB["public route table<br/>0.0.0.0/0 → IGW"]
    RTPRI["private route tables<br/>0.0.0.0/0 → NAT · S3 prefix → gateway endpoint"]
    EP["interface endpoints in private subnets<br/>ecr.api · ecr.dkr · sts · secretsmanager · kms · logs · eks-auth"]
  end
  IGW --- RTPUB
  RTPUB --- PUBA & PUBB & PUBC
  RTPRI --- PRIA & PRIB & PRIC
  PRIA & PRIB & PRIC --- EP
```

| Security group | Inbound | Outbound |
|---|---|---|
| `alb` | 443 from 0.0.0.0/0 (or WAF/CloudFront prefix list) | target port to `nodes` |
| `nodes` | from `alb` on target ports; node-to-node all (CNI); control plane on 443/10250 | 443 to endpoints and NAT |
| `cluster` (EKS-managed) | 443 from `nodes` | 10250/443 to `nodes` |
| `vpc-endpoints` | 443 from `nodes` | — |
| Pods (optional, SG-for-pods) | per workload, e.g. backend only from frontend pods | per workload |

- Nodes and pods have **no public IPs**. The EKS API endpoint is **private + public restricted to an allow-list CIDR**, and private-only once a VPN or bastion exists.
- `dev` uses **one NAT gateway** (cost). `staging`/prod use one per AZ (availability).
- Kubernetes NetworkPolicy is enforced by the **VPC CNI network policy agent** (eBPF). Phase 6 policies carry over unchanged. Cilium's L7/FQDN policies don't; their AWS equivalents are security groups for pods plus egress through NAT and endpoints only.

## 3. Identity

```mermaid
flowchart LR
  subgraph HUMAN["Humans"]
    U["Engineer"] --> IDC["IAM Identity Center (MFA)"]
    IDC --> PS["permission set → IAM role<br/>eks-admin / eks-developer / eks-readonly"]
    PS --> AE["EKS access entry<br/>kubernetes_groups: lab:platform-admins / lab:developers / lab:auditors"]
    AE --> RBAC["Kubernetes RBAC<br/>(same ClusterRoles/Roles as local)"]
    BG["break-glass role<br/>MFA · 2 people · alarmed"] --> AEBG["access entry → AmazonEKSClusterAdminPolicy"]
  end
  subgraph CI["GitHub Actions"]
    GHA["workflow run<br/>OIDC token: repo, ref, environment"] --> STS["sts:AssumeRoleWithWebIdentity<br/>trust: sub = repo:resumepilot360/platform-engineering-lab:…"]
    STS --> R1["ci-ecr-push<br/>ecr:PutImage on demo-* only"]
    STS --> R2["tf-plan<br/>ReadOnly + state read"]
    STS --> R3["tf-apply<br/>environment: production approval"]
  end
  subgraph PODS["Workloads"]
    SA["ServiceAccount external-secrets/external-secrets"] --> PIA["EKS Pod Identity association"]
    PIA --> RESO["role eso-ENV<br/>secretsmanager:GetSecretValue on ENV/demo/*<br/>kms:Decrypt on secrets-ENV key"]
    SA2["ServiceAccount kube-system/aws-load-balancer-controller"] --> PIA2["Pod Identity"] --> RLBC["role lbc (AWS-managed policy doc)"]
  end
```

| Local lab | AWS |
|---|---|
| x509 persona certs (24h) | Identity Center SSO → role session (1–12h) |
| Group in cert `O=` | `kubernetes_groups` on the access entry |
| Impersonation break-glass | Separate MFA role + access entry, CloudTrail alarm on use |
| `system:masters` bootstrap kubeconfig | `bootstrap_cluster_creator_admin_permissions = false`; admin only via access entry |
| `GITHUB_TOKEN` (GHCR) | GitHub OIDC → STS, no access keys anywhere |
| ESO → OpenBao Kubernetes auth | ESO → **Pod Identity** → Secrets Manager |

## 4. GitOps and supply chain on EKS

```mermaid
sequenceDiagram
  autonumber
  actor Dev as Developer
  participant Git as GitHub (main)
  participant CI as Actions: ci
  participant STS as AWS STS
  participant ECR as ECR
  participant Argo as Argo CD (EKS)
  participant K as Kyverno
  participant EKS as demo-ENV
  Dev->>Git: merge change
  Git->>CI: trigger
  CI->>CI: tests · govulncheck · Semgrep · build · Trivy
  CI->>STS: OIDC token → ci-ecr-push role (15 min)
  CI->>ECR: push digest (immutable tag sha-xxxx)
  CI->>CI: Syft SBOM · Cosign keyless sign + attest
  CI->>Git: pin digest in gitops/environments/dev
  Argo->>Git: poll / webhook
  Argo->>EKS: sync
  EKS->>K: admission: registry = ECR, signature from ci.yaml@main, limits, labels
  K-->>EKS: allow (or deny unsigned / foreign image)
  Argo->>EKS: PostSync smoke Job
  Note over Dev,EKS: staging/prod: promotion PR copies digests, production environment approval, manual prod sync
```

## 5. Secrets and keys

```mermaid
flowchart LR
  TF["Terraform<br/>creates secret containers + KMS keys<br/>(never values)"] --> SMS[("Secrets Manager<br/>dev/demo/backend")]
  ROT["Rotation Lambda / RDS managed rotation"] --> SMS
  KMSK["KMS CMK secrets-dev<br/>key policy: admin = tf-apply · use = eso-dev"] -. "encrypts" .-> SMS
  ESO["ESO (Pod Identity role eso-dev)"] -- "GetSecretValue" --> SMS
  ESO --> KS[("Kubernetes Secret<br/>envelope-encrypted with KMS eks-secrets")]
  KS --> POD["demo-backend (volume mount)"]
  CT["CloudTrail"] -. "GetSecretValue / Decrypt events" .-> AL["EventBridge alarm<br/>unexpected principal · key disable/deletion"]
```

The same `ExternalSecret` manifests as locally. Only the `SecretStore` provider changes:
`aws: {service: SecretsManager, region: us-east-1}` with no static credentials, since Pod Identity supplies them.

## 6. Terraform layout and ownership

```mermaid
flowchart TB
  subgraph TFREPO["terraform/"]
    MODS["modules/<br/>network · eks · iam-github-oidc · iam-access · ecr · kms · secrets · observability · addons"]
    ENVS["environments/dev · environments/staging<br/>(composition + tfvars, no secrets)"]
  end
  STATE[("S3 state bucket per account<br/>versioning · SSE-KMS · use_lockfile")]
  PR["Pull request"] --> PLAN["terraform-plan workflow<br/>role tf-plan (read-only)<br/>plan posted to PR"]
  PLAN --> REVIEW["Human review of the plan"]
  REVIEW --> APPLY["terraform-apply workflow<br/>environment approval → role tf-apply<br/>applies the reviewed plan file"]
  APPLY --> STATE
  ENVS --> MODS
  APPLY --> AWSRES["AWS: VPC · EKS · node groups · add-ons · IAM · KMS · ECR · Secrets Manager containers · CloudWatch · Argo CD bootstrap"]
  AWSRES --> ARGOHAND["Argo CD takes over all Kubernetes config<br/>(namespaces, RBAC, policies, apps)"]
```

| Owner | Resources | Never owns |
|---|---|---|
| **Terraform** | VPC, subnets, routes, SGs, endpoints, EKS + node groups + add-ons, IAM roles/policies, access entries, Pod Identity associations, KMS, ECR, Secrets Manager *containers*, log groups, Argo CD Helm release + root app | Kubernetes app config, secret values |
| **Argo CD** | Namespaces, RBAC, Kyverno policies, SecretStores/ExternalSecrets, workloads | Anything in AWS |
| **GitHub Actions** | Images in ECR, dev digest pins, promotion PRs, Terraform runs (via roles) | Long-lived credentials |

## 7. Security controls

| Control | AWS implementation |
|---|---|
| Encryption at rest | KMS CMKs: EKS Secrets, EBS (gp3), ECR, Secrets Manager, CloudWatch Logs, S3 state |
| Encryption in transit | ALB TLS (ACM), VPC endpoints (TLS), API server TLS |
| Least privilege | Role per function, `aws:SourceIdentity`/session tags, permission boundaries for `tf-apply` |
| No static credentials | Identity Center, GitHub OIDC, Pod Identity; SCP denying `iam:CreateAccessKey` |
| Admission | Kyverno (ECR-only registry, Cosign signature by `ci.yaml@main`, limits, labels) + Pod Security `restricted` |
| Runtime detection | GuardDuty EKS Runtime Monitoring (managed) or Falco DaemonSet (same rules as local) |
| Audit | EKS `api`, `audit`, `authenticator` logs → CloudWatch; CloudTrail for every AWS API call |
| Network | Private nodes, SGs, NetworkPolicy (VPC CNI), endpoints, optional WAF on the ALB |
| Image hygiene | ECR scan on push + Trivy in CI, immutable tags, lifecycle policy |

## 8. Cost estimate (dev, us-east-1, on-demand list prices; verify in the AWS Pricing Calculator before approval)

| Item | Sizing | ≈ USD / month |
|---|---|---|
| EKS control plane | 1 cluster × $0.10/h | 73 |
| Nodes | 2 × t4g.medium (Graviton) | 49 |
| EBS | 2 × 30 GiB gp3 node volumes + 10 GiB PVs | 6 |
| NAT gateway | 1 × $0.045/h + data processing | 33 + data |
| ALB | 1 ALB + low LCU | 18 |
| VPC interface endpoints | 6 endpoints × 1 AZ (dev) × $0.01/h | 44 |
| KMS | 4 keys | 4 |
| Secrets Manager | ~5 secrets | 2 |
| CloudWatch Logs | ~5 GiB ingest (control-plane audit is chatty) | 3–10 |
| Route 53 + ACM | hosted zone (ACM public certs are free) | 1 |
| ECR | < 5 GiB | < 1 |
| **Total (dev, running 24/7)** | | **≈ $235–250 + data transfer** |

Cost levers: stop node groups outside lab hours (scale to 0); drop interface
endpoints in dev and route through NAT (−$44, less private); use Spot for nodes;
**tear down when idle**, since the control plane alone is ~$2.40/day.
Staging with NAT and endpoints in 3 AZs adds about $120/month on top of dev.

## 9. Teardown order (Phase 8 runbook)

1. Argo CD: delete the `demo-*` Applications (finalizers remove workloads and their ALB-backed Ingresses).
2. Confirm the AWS Load Balancer Controller has removed every ALB and target group: `aws elbv2 describe-load-balancers`. Orphaned ALBs block VPC deletion.
3. Delete PVCs (EBS volumes) or confirm their reclaim policy.
4. `terraform destroy` in `environments/dev` (add-ons → node groups → EKS → endpoints → NAT → VPC).
5. KMS keys enter a **7–30 day pending deletion** window: schedule deletion deliberately, never automatically.
6. Keep the state bucket until the final destroy is verified, then empty it and delete it.
7. Verify zero cost: Cost Explorer filtered on the `project=platform-lab` tag the next day.

## 10. Local lab → AWS mapping

| Concern | Local | AWS |
|---|---|---|
| Control plane | K3s single server | EKS managed, multi-AZ |
| Nodes | k3d agent containers | Managed node group, Graviton |
| CNI / policy | Cilium | VPC CNI + network policy agent |
| Ingress | Traefik NodePort on 127.0.0.1 | AWS LB Controller → ALB + ACM + WAF |
| DNS | `*.lab.localhost` | Route 53 |
| Registry | GHCR + pull-through caches | ECR + pull-through cache rules |
| Human access | x509 personas, impersonation break-glass | Identity Center → roles → access entries |
| Workload identity | ServiceAccount tokens (OpenBao auth) | EKS Pod Identity |
| CI identity | `GITHUB_TOKEN` | GitHub OIDC → STS |
| Secrets | OpenBao + ESO | Secrets Manager + ESO |
| Keys | secretbox key on the server's disk, Shamir unseal | KMS CMKs (HSM-backed, audited) |
| Storage | local-path (node-local) | EBS CSI gp3 (AZ-bound) |
| Audit | API audit file, OpenBao audit stdout | CloudWatch EKS logs, CloudTrail |
| Runtime detection | Falco | GuardDuty EKS Runtime or Falco |
| Delivery | Argo CD from GitHub | same |
