"""AWS (EKS) architecture diagrams with official AWS architecture icons.

Regenerate (needs Graphviz and the `diagrams` package):
    brew install graphviz
    python3 -m venv .venv && .venv/bin/pip install diagrams==0.25.1
    .venv/bin/python docs/diagrams/aws_architecture.py

Writes PNGs to docs/images/aws/. Design only; see docs/aws-architecture.md.
"""
from pathlib import Path

from diagrams import Cluster, Edge
from diagrams.aws.compute import EC2, ECR, EKS, Lambda
from diagrams.aws.general import Users
from diagrams.aws.management import Cloudtrail, Cloudwatch
from diagrams.aws.network import (ALB, Endpoint, InternetGateway, NATGateway,
                                  PrivateSubnet, PublicSubnet, Route53, VPCRouter)
from diagrams.aws.security import (ACM, IAMAWSSts, IAMRole, KMS, WAF, Guardduty,
                                   SecretsManager, SingleSignOn)
from diagrams.aws.storage import EBS, S3
from diagrams.k8s.compute import Pod
from diagrams.k8s.podconfig import Secret
from diagrams.k8s.rbac import SA, Group
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.iac import Terraform
from diagrams.onprem.vcs import Github

import importlib.util

_spec = importlib.util.spec_from_file_location("_style", Path(__file__).with_name("_style.py"))
_style = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_style)
from functools import partial
CLUSTER, FLOW, GREEN, BLUE, ORANGE, RED, PURPLE = (_style.CLUSTER, _style.FLOW, _style.GREEN,
                                                    _style.BLUE, _style.ORANGE, _style.RED, _style.PURPLE)
AWS_CLOUD, REGION, VPC_STYLE, PUBLIC, PRIVATE, EKS_STYLE, NEUTRAL, GITHUB = (
    _style.AWS_CLOUD, _style.REGION, _style.VPC_STYLE, _style.PUBLIC, _style.PRIVATE,
    _style.EKS_STYLE, _style.NEUTRAL, _style.GITHUB)

OUT = Path(__file__).resolve().parent.parent / "images" / "aws"
OUT.mkdir(parents=True, exist_ok=True)
diagram = partial(_style.diagram, OUT)


# 1. Overview -----------------------------------------------------------------
# Compact top-to-bottom layout: GitHub embeds images at page width, so the
# canvas must stay small for large fonts to remain legible after scaling.
BIG = lambda bg, border: {**CLUSTER(bg, border), "fontsize": "30", "margin": "18"}
BIGFLOW = lambda label, color="#3b4a5a", style="solid": Edge(
    label=f" {label} " if label else "", color=color, fontcolor=color, style=style,
    penwidth="3.5", fontsize="26", fontname="Helvetica Bold")
with diagram("aws-overview", "Platform Lab on AWS: components (design)", direction="TB",
             graph={"fontsize": "48", "nodesep": "1.5", "ranksep": "0.9", "pad": "0.4", "dpi": "96"},
             node={"fontsize": "26", "fontname": "Helvetica Bold"}):
    with Cluster("GitHub", graph_attr=BIG("#f6f8fa", "#24292f")):
        repo = Github("Git repo")
        actions = GithubActions("Actions")
    users = Users("Users")
    engineers = Users("Engineers")

    with Cluster("AWS account · us-east-1", graph_attr=BIG("#f7f9fa", "#232f3e")):
        with Cluster("Edge", graph_attr=BIG("#ffffff", "#8c4fff")):
            dns = Route53("Route 53")
            waf = WAF("WAF")
            cert = ACM("ACM")
        with Cluster("Identity", graph_attr=BIG("#ffffff", "#dd344c")):
            sso = SingleSignOn("Identity\nCenter")
            sts = IAMAWSSts("STS (OIDC)")
            roles = IAMRole("IAM roles")

        with Cluster("VPC · 3 AZs", graph_attr=BIG("#f2f8ea", "#7aa116")):
            alb = ALB("ALB")
            nat = NATGateway("NAT")
            with Cluster("Amazon EKS (private subnets)", graph_attr=BIG("#fdf1e6", "#ed7100")):
                argo = ArgoCD("Argo CD")
                app = Pod("Demo apps")
                eso = Pod("External\nSecrets")
                nodes = EC2("Graviton\nnodes")
            vpce = Endpoint("VPC\nendpoints")

        with Cluster("Images, secrets, keys", graph_attr=BIG("#ffffff", "#147eba")):
            ecr = ECR("ECR")
            sm = SecretsManager("Secrets\nManager")
            kms = KMS("KMS")
            s3 = S3("Terraform\nstate (S3)")
        with Cluster("Logging and detection", graph_attr=BIG("#ffffff", "#e7157b")):
            cw = Cloudwatch("CloudWatch")
            ct = Cloudtrail("CloudTrail")
            gd = Guardduty("GuardDuty")

    users >> BIGFLOW("HTTPS", GREEN) >> dns >> waf >> alb >> BIGFLOW("", GREEN) >> app
    cert >> BIGFLOW("", GREEN, "dashed") >> alb
    engineers >> BIGFLOW("SSO", BLUE) >> sso >> roles
    actions >> BIGFLOW("OIDC", BLUE) >> sts >> roles
    roles >> BIGFLOW("access entry", BLUE) >> argo
    repo >> BIGFLOW("GitOps", ORANGE) >> argo >> BIGFLOW("sync", ORANGE) >> app
    actions >> BIGFLOW("push", ORANGE) >> ecr
    nodes >> BIGFLOW("", "#555555", "dashed") >> vpce >> BIGFLOW("pull", ORANGE) >> ecr
    eso >> BIGFLOW("secrets", RED) >> vpce >> BIGFLOW("", RED) >> sm >> BIGFLOW("", RED, "dashed") >> kms
    nodes >> BIGFLOW("", "#555555", "dashed") >> nat
    vpce >> BIGFLOW("logs", "#555555", "dashed") >> cw
    ct - Edge(style="invis") - gd


# 2. Network ------------------------------------------------------------------
with diagram("aws-network", "Network: VPC, subnets, routing", direction="TB"):
    igw = InternetGateway("Internet gateway")
    with Cluster("VPC 10.20.0.0/16", graph_attr=VPC_STYLE):
        rt_pub = VPCRouter("Public route table\n0.0.0.0/0 → IGW")
        rt_pri = VPCRouter("Private route tables\n0.0.0.0/0 → NAT\nS3 → gateway endpoint")
        azs = []
        # Declared c, a, b: Graphviz's crossing minimisation then lays them out a, b, c.
        for az, n in (("c", 8), ("a", 0), ("b", 4)):
            with Cluster(f"Availability Zone {az}", graph_attr=NEUTRAL):
                with Cluster(f"public 10.20.{n}.0/22", graph_attr=PUBLIC):
                    pub = PublicSubnet("ALB node\n" + ("NAT gateway" if az == "a" else ""))
                with Cluster(f"private 10.20.{32 * (n // 4 + 1)}.0/19", graph_attr=PRIVATE):
                    pri = PrivateSubnet("EKS nodes + pods\n(VPC CNI pod IPs)")
                azs.append((pub, pri))
        endpoints = Endpoint("Interface endpoints\n(private subnets)")
    igw >> FLOW("", GREEN) >> rt_pub
    for pub, pri in azs:
        rt_pub >> FLOW("", GREEN) >> pub
        rt_pri >> FLOW("", BLUE) >> pri
        pri >> FLOW("", BLUE, "dashed") >> endpoints


# 3. Identity -----------------------------------------------------------------
with diagram("aws-identity", "Identity: humans, CI and workloads (no static credentials)"):
    with Cluster("Humans", graph_attr=NEUTRAL):
        eng = Users("Engineer")
        sso = SingleSignOn("Identity Center\n(MFA)")
        hrole = IAMRole("eks-admin\neks-developer\neks-readonly")
        bg = IAMRole("break-glass\n(MFA, alarmed)")
    with Cluster("GitHub Actions", graph_attr=GITHUB):
        gha = GithubActions("workflow run\n(OIDC token: repo, ref, env)")
    with Cluster("AWS IAM", graph_attr=AWS_CLOUD):
        sts = IAMAWSSts("STS\nAssumeRoleWithWebIdentity")
        ci_role = IAMRole("ci-ecr-push")
        plan_role = IAMRole("tf-plan (read-only)")
        apply_role = IAMRole("tf-apply\n(env approval)")
        eso_role = IAMRole("eso-dev\nGetSecretValue dev/*\nkms:Decrypt dev key")
    with Cluster("Amazon EKS", graph_attr=EKS_STYLE):
        eks = EKS("access entries")
        groups = Group("K8s groups\nlab:platform-admins\nlab:developers · lab:auditors")
        sa = SA("ServiceAccount\nexternal-secrets")
    eng >> FLOW("SSO", BLUE) >> sso >> FLOW("permission set", BLUE) >> hrole >> FLOW("access entry", BLUE) >> eks
    bg >> FLOW("ClusterAdmin policy", RED, "dashed") >> eks
    eks >> FLOW("kubernetes_groups", BLUE) >> groups
    gha >> FLOW("OIDC", ORANGE) >> sts
    sts >> ci_role
    sts >> plan_role
    sts >> apply_role
    sa >> FLOW("EKS Pod Identity", RED) >> eso_role


# 4. CI/CD + GitOps -----------------------------------------------------------
with diagram("aws-cicd-gitops", "Delivery: CI → ECR → Git → Argo CD → EKS"):
    dev = Users("Developer")
    with Cluster("GitHub", graph_attr=GITHUB):
        repo = Github("main branch")
        ci = GithubActions("ci: test · govulncheck\nSemgrep · build · Trivy\nSyft SBOM · Cosign sign")
        promote = GithubActions("promote: PR\n(production approval)")
    with Cluster("AWS", graph_attr=AWS_CLOUD):
        sts = IAMAWSSts("STS (OIDC)")
        ecr = ECR("ECR\nimmutable · scan on push")
        with Cluster("Amazon EKS", graph_attr=EKS_STYLE):
            argo = ArgoCD("Argo CD")
            kyv = Pod("Kyverno admission\nECR only · signed by ci.yaml")
            with Cluster("demo-dev / demo-staging / demo-prod", graph_attr=NEUTRAL):
                app = Pod("demo apps\n+ PostSync smoke test")
    dev >> FLOW("1  merge", "#3b4a5a") >> repo >> FLOW("2  trigger") >> ci
    ci >> FLOW("3  OIDC → role", BLUE) >> sts
    ci >> FLOW("4  push digest + signature", ORANGE) >> ecr
    ci >> FLOW("5  pin digest (dev)", ORANGE) >> repo
    dev >> FLOW("staging / prod", PURPLE, "dashed") >> promote >> FLOW("PR", PURPLE, "dashed") >> repo
    repo >> FLOW("6  pull", ORANGE) >> argo >> FLOW("7  sync", ORANGE) >> kyv >> FLOW("8  admit", GREEN) >> app
    app >> FLOW("pull image", ORANGE, "dashed") >> ecr


# 5. Secrets and keys ---------------------------------------------------------
with diagram("aws-secrets", "Secrets and encryption keys"):
    tf = Terraform("Terraform\ncreates containers + keys\n(never values)")
    rot = Lambda("Rotation Lambda /\nRDS managed rotation")
    with Cluster("AWS", graph_attr=AWS_CLOUD):
        sm = SecretsManager("Secrets Manager\ndev/demo/backend")
        kms_s = KMS("KMS secrets-dev\n(use: eso-dev only)")
        kms_e = KMS("KMS eks-secrets\n(envelope encryption)")
        role = IAMRole("eso-dev role")
        trail = Cloudtrail("CloudTrail\naudit events")
        alarm = Cloudwatch("CloudWatch alarm\nunexpected access")
    with Cluster("Amazon EKS · demo-dev", graph_attr=EKS_STYLE):
        eso = Pod("External Secrets\nOperator")
        ksec = Secret("Secret\ndemo-backend-db")
        pod = Pod("demo-backend\n(read-only volume)")
    tf >> FLOW("", PURPLE) >> sm
    tf >> FLOW("", PURPLE) >> kms_s
    rot >> FLOW("rotate", RED) >> sm
    sm >> FLOW("encrypted by", RED, "dashed") >> kms_s
    eso >> FLOW("Pod Identity", BLUE) >> role >> FLOW("GetSecretValue", RED) >> sm
    eso >> FLOW("writes", ORANGE) >> ksec >> FLOW("mount", ORANGE) >> pod
    ksec >> FLOW("encrypted at rest", RED, "dashed") >> kms_e
    sm >> FLOW("events", "#555555", "dashed") >> trail >> alarm


# 6. Terraform ----------------------------------------------------------------
with diagram("aws-terraform", "Terraform: plan, review, approve, apply"):
    dev = Users("Engineer")
    with Cluster("GitHub", graph_attr=GITHUB):
        pr = Github("Pull request\nterraform/ changes")
        plan = GithubActions("terraform-plan\nrole tf-plan (read-only)\nplan posted to PR")
        apply = GithubActions("terraform-apply\nenvironment approval\nrole tf-apply")
    with Cluster("AWS", graph_attr=AWS_CLOUD):
        state = S3("S3 state\nversioned · KMS · lockfile")
        tfnode = Terraform("modules: network · eks\niam · ecr · kms · secrets\nobservability · addons")
        eks = EKS("EKS + add-ons\n+ Argo CD bootstrap")
        argo = ArgoCD("Argo CD owns all\nKubernetes config")
    dev >> FLOW("1  open PR", "#3b4a5a") >> pr >> FLOW("2") >> plan
    plan >> FLOW("3  human review", PURPLE, "dashed") >> apply
    apply >> FLOW("4  apply reviewed plan", PURPLE) >> tfnode >> eks >> FLOW("handover", ORANGE) >> argo
    plan >> FLOW("read", "#555555", "dashed") >> state
    apply >> FLOW("write + lock", PURPLE) >> state

print("\n".join(sorted(p.name for p in OUT.glob("*.png"))))
