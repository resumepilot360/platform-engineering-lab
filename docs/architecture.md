# Architecture

Local, production-inspired platform on k3d (Apple Silicon), with GitHub as the
source of truth and an AWS/EKS design to follow in Phase 8. Versions are pinned
in [`local/versions.env`](../local/versions.env). Every endpoint is linked from
the lab portal, **http://lab.localhost:8081**. The AWS/EKS target design is in
[aws-architecture.md](aws-architecture.md).

## 1. Components

```mermaid
flowchart LR
  subgraph GH["GitHub (public): resumepilot360/platform-engineering-lab"]
    direction TB
    REPO[("Git repo, main<br/>source of truth")]
    ACT["GitHub Actions<br/>ci · promote · validate"]
    GHCR[("GHCR<br/>demo-backend / demo-frontend<br/>amd64 + arm64, by digest")]
    ENV["Environments<br/>staging · production (required reviewer)"]
  end

  subgraph HOST["macOS host (Apple Silicon) · Docker Desktop 6 vCPU / 15 GiB"]
    direction TB
    USER(["You: browser · kubectl · k9s · gh"])
    subgraph REG["Registries (outside cluster lifecycle)"]
      LREG[("k3d-registry.localhost:5001<br/>approved local images")]
      MIR[("Pull-through caches<br/>quay.io :5011 · Docker Hub :5012 · ghcr.io :5013")]
    end
    LB["k3d serverlb<br/>127.0.0.1:6550 → API<br/>127.0.0.1:8081/8443 → Traefik NodePort"]

    subgraph K3D["k3d cluster: platform-lab · K3s v1.35.5 · 1 server + 2 agents · SQLite · secretbox encryption at rest · audit log"]
      direction TB
      subgraph KS["kube-system"]
        CIL["Cilium 1.20 CNI<br/>+ Hubble relay"]
        TRA["Traefik Ingress<br/>NodePort 30080/30443"]
        SYS["CoreDNS · metrics-server<br/>local-path storage"]
      end
      subgraph ARGO["argocd"]
        ACD["Argo CD 3.5<br/>app-of-apps · projects: platform, demo"]
      end
      subgraph SEC["Secrets"]
        BAO["openbao: OpenBao 2.7<br/>raft · Shamir 3/2 · audit"]
        ESO["external-secrets: ESO 2.14"]
      end
      subgraph APPS["demo-dev · demo-staging · demo-prod"]
        FE["demo-frontend"] --> BE["demo-backend"]
        SS["SecretStore + ExternalSecret"] --> K8SSEC[("Secret demo-backend-db")]
        K8SSEC -. volume .-> BE
      end
      PORTAL["lab-portal<br/>lab.localhost"]
    end
  end

  USER --> LB
  LB --> TRA
  TRA --> FE
  TRA --> PORTAL
  TRA --> ACD
  REPO -- "poll every 60s" --> ACD
  ACD -- "sync" --> APPS
  ACD -- "sync" --> PORTAL
  ACT -- "push image" --> GHCR
  ACT -- "bot commit: dev digests" --> REPO
  ACT -. "promotion PR" .-> REPO
  ENV -. "gates prod promotion" .-> ACT
  GHCR -- "pull via cache" --> MIR
  MIR --> K3D
  LREG --> K3D
  ESO -- "Kubernetes auth (audience openbao)" --> BAO
  ESO --> SS
```

| Layer | Tool | Why (decision record) |
|---|---|---|
| Cluster | k3d + K3s v1.35.5, single server, SQLite | Survives Docker IP changes that broke the 3-server etcd `dev-cluster` ([0001](decisions/0001-single-server-topology.md)) |
| CNI / network policy | Cilium 1.20 (kube-proxy kept), Hubble | L3–L7 and FQDN policy for Phase 6 ([0002](decisions/0002-cilium-cni.md)) |
| Ingress | Traefik (bundled) via NodePort, loopback only | ingress-nginx retired; no hostPort under Cilium ([0003](decisions/0003-ingress-traefik-nodeport.md)) |
| Images | Local registry + pull-through caches; GHCR for CI output | Rebuilds in ~30s; one approved source ([0004](decisions/0004-local-registry.md)) |
| Manifests | Kustomize (first-party), pinned Helm charts (third-party) | One tool per ownership type ([0005](decisions/0005-manifest-tooling-and-layout.md)) |
| Tenancy | Restricted Pod Security, LimitRange, ResourceQuota | Built-in guardrails before Kyverno ([0006](decisions/0006-namespace-baseline.md)) |
| Identity | x509 personas (24h), group RBAC, impersonation break-glass, audit log | Real authentication, least privilege ([0007](decisions/0007-human-identity-and-break-glass.md), [IAM model](iam-model.md)) |
| Secrets | OpenBao + External Secrets, secretbox at rest | Store-agnostic delivery; on AWS only the provider changes ([0008](decisions/0008-secrets-architecture.md), [secrets model](secrets-model.md)) |
| Delivery | GitHub Actions (CI) + Argo CD (CD), digest promotion | One owner per resource; tested bytes ship ([0009](decisions/0009-gitops-ownership.md)) |

## 2. GitOps flow: commit to prod, and rollback

```mermaid
sequenceDiagram
  autonumber
  actor Dev as Developer
  participant Git as GitHub repo (main)
  participant CI as Actions: ci
  participant Reg as GHCR
  participant Argo as Argo CD
  participant D as demo-dev
  participant S as demo-staging
  participant P as demo-prod
  actor Rev as Reviewer (production env)

  Dev->>Git: merge change under applications/
  Git->>CI: push trigger
  CI->>CI: go vet · unit + integration tests · govulncheck · Semgrep
  CI->>CI: build amd64 candidate · Trivy gate 1 (fixable HIGH/CRITICAL)
  CI->>Reg: push sha-xxxx (amd64 + arm64)
  CI->>CI: Trivy gate 2 on the published arm64 digest
  CI->>Git: bot commit, pin digests in gitops/environments/dev
  Argo->>Git: poll (60s)
  Argo->>D: auto-sync (prune, self-heal)
  Argo->>D: PostSync smoke Job: frontend → backend → secret
  Note over D: smoke fails → sync Failed → git revert the deploy commit (≈12s rollback)
  Dev->>CI: gh workflow run promote -f to=staging
  CI->>Git: PR copies dev digests → staging (no rebuild)
  Dev->>Git: review + merge PR
  Argo->>S: auto-sync + smoke Job
  Dev->>CI: gh workflow run promote -f to=prod
  CI-->>Rev: waiting for production environment approval
  Rev->>CI: approve
  CI->>Git: PR copies staging digests → prod
  Rev->>Git: review + merge PR
  Note over Argo,P: prod is manual sync: OutOfSync until a human syncs
  Rev->>Argo: Sync demo-prod
  Argo->>P: sync + smoke Job
  Note over P: drift in prod is detected (OutOfSync), never auto-reverted
```

## 3. Secrets flow

```mermaid
flowchart LR
  OP["Operator<br/>rotate-secret.sh<br/>(scoped token, CAS write)"] -- "HTTP API via port-forward<br/>(no secrets in exec args)" --> KV
  subgraph BAO["OpenBao (namespace openbao)"]
    KV[("kv-dev / kv-staging / kv-prod<br/>KV v2, versioned")]
    POL["policy demo-ENV-read<br/>read kv-ENV/data/demo/*"]
    ROLE["role eso-demo-ENV<br/>SA eso-reader · ns demo-ENV · aud openbao · 15m TTL"]
    AUD["audit device: stdout<br/>values HMAC'd"]
  end
  subgraph NS["namespace demo-ENV"]
    SA["SA eso-reader<br/>(no K8s permissions)"]
    SS["SecretStore openbao"]
    XS["ExternalSecret demo-backend-db<br/>refresh 1m"]
    S[("Secret demo-backend-db<br/>encrypted at rest: secretbox")]
    POD["demo-backend pod<br/>read-only volume, 0400"]
  end
  ESO["ESO controller"] -- "TokenRequest (aud openbao)" --> SA
  ESO -- "login" --> ROLE
  ROLE --> POL --> KV
  SS --> ESO
  XS --> ESO
  ESO -- "write" --> S
  S --> POD
```

## 4. Ownership layers (no resource has two owners)

```mermaid
flowchart TB
  TF["Terraform (Phase 8 / AWS)<br/>VPC · EKS · IAM · KMS · ECR · Secrets Manager"]
  BOOT["Bootstrap: scripts/cluster-up.sh<br/>k3d cluster · Cilium · bootstrap namespaces<br/>ESO + OpenBao Helm · OpenBao init/unseal · Argo CD + root app"]
  subgraph ARGOOWN["Argo CD (from Git)"]
    PLAT["project platform<br/>namespaces · RBAC · secret stores · portal"]
    DEMO["project demo<br/>workloads only in demo-*<br/>no Secrets, Roles, quotas, NetworkPolicies"]
  end
  CIOWN["GitHub Actions<br/>images in GHCR · dev digest pins · promotion PRs"]
  TF -.-> BOOT --> ARGOOWN
  CIOWN --> DEMO
```

## 5. Local vs AWS (target for Phase 8)

| Concern | Local lab | AWS |
|---|---|---|
| Control plane | K3s single server (SQLite) | EKS managed, multi-AZ |
| Nodes | 2 k3d agents (containers) | Managed node groups / Karpenter, Graviton (arm64 images already built) |
| CNI | Cilium (tunnel) | VPC CNI (+ Cilium chaining optional), security groups for pods |
| Ingress | Traefik NodePort on 127.0.0.1 | AWS Load Balancer Controller → ALB, ACM TLS |
| Registry | GHCR + local caches | ECR (+ pull-through cache rules), scan on push |
| Human access | x509 personas, impersonation break-glass | IAM Identity Center → IAM roles → EKS access entries; MFA break-glass role |
| Workload → cloud | none | EKS Pod Identity |
| CI identity | `GITHUB_TOKEN` | GitHub OIDC → STS role (ECR push only) |
| Secrets | OpenBao + ESO | Secrets Manager + ESO (Pod Identity), KMS CMK per environment |
| Encryption at rest | secretbox, key on the server's disk | EKS envelope encryption with KMS |
| Audit | API audit log on server-0, OpenBao audit stdout | EKS control-plane logs → CloudWatch, CloudTrail |
| Delivery | Argo CD from GitHub | same |
