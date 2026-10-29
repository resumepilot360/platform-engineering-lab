"""AWS (EKS) architecture diagrams with official AWS architecture icons.

Regenerate (needs Graphviz and the `diagrams` package):
    brew install graphviz
    python3 -m venv .venv && .venv/bin/pip install diagrams==0.25.1
    .venv/bin/python docs/diagrams/aws_architecture.py

Writes PNGs to docs/images/aws/. Design only; see docs/aws-architecture.md.
"""
from pathlib import Path

import diagrams
from diagrams import Cluster, Diagram, Edge
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

# diagrams sizes each node from its label's line count (explicit `height` is
# overridden). A leading blank line buys one line of space between icon and
# label, so larger fonts no longer overlap the icon.
_node_init = diagrams.Node.__init__
def _padded_init(self, label="", *args, **kwargs):
    _node_init(self, "\n" + label if label else label, *args, **kwargs)
diagrams.Node.__init__ = _padded_init

OUT = Path(__file__).resolve().parent.parent / "images" / "aws"
OUT.mkdir(parents=True, exist_ok=True)

# Large, high-contrast styling: readable in GitHub light and dark mode.
# Curved splines keep edge labels on their edges (orthogonal routing scatters them).
GRAPH = {"fontsize": "40", "fontname": "Helvetica Bold", "bgcolor": "white", "pad": "0.6",
         "nodesep": "1.0", "ranksep": "1.4", "dpi": "110", "labelloc": "t", "splines": "spline"}
NODE = {"fontsize": "22", "fontname": "Helvetica", "fontcolor": "#16191f"}
EDGE = {"fontsize": "24", "fontname": "Helvetica Bold", "fontcolor": "#16191f", "penwidth": "2.6", "color": "#3b4a5a"}
CLUSTER = lambda bg, border: {"fontsize": "28", "fontname": "Helvetica Bold", "bgcolor": bg,
                              "pencolor": border, "penwidth": "2.5", "margin": "24", "style": "rounded"}

AWS_CLOUD = CLUSTER("#f7f9fa", "#232f3e")
REGION = CLUSTER("#ffffff", "#147eba")
VPC_STYLE = CLUSTER("#f2f8ea", "#7aa116")
PUBLIC = CLUSTER("#e9f3e6", "#7aa116")
PRIVATE = CLUSTER("#e6f2f8", "#147eba")
EKS_STYLE = CLUSTER("#fdf1e6", "#ed7100")
NEUTRAL = CLUSTER("#f4f4f4", "#8c8c8c")
GITHUB = CLUSTER("#f6f8fa", "#24292f")

FLOW = lambda label, color="#3b4a5a", style="solid": Edge(
    label=f"  {label}  " if label else "", color=color, fontcolor=color, style=style, penwidth="3",
    fontsize="24", fontname="Helvetica Bold")
ORANGE, BLUE, GREEN, RED, PURPLE = "#d45b07", "#147eba", "#3f8624", "#c7131f", "#7b3fbf"


def diagram(name, title, direction="LR"):
    return Diagram(title, filename=str(OUT / name), outformat="png", show=False,
                   direction=direction, graph_attr=GRAPH, node_attr=NODE, edge_attr=EDGE)


# 1. Overview -----------------------------------------------------------------
with diagram("aws-overview", "Platform Lab on AWS: EKS architecture (design)"):
    users = Users("Internet users")
    engineer = Users("Engineers")

    with Cluster("GitHub", graph_attr=GITHUB):
        repo = Github("platform-engineering-lab\n(source of truth)")
        actions = GithubActions("Actions\nci · promote · terraform")

    with Cluster("AWS account (dev / staging)  ·  us-east-1", graph_attr=AWS_CLOUD):
        sso = SingleSignOn("IAM Identity Center\n(SSO + MFA)")
        sts = IAMAWSSts("STS\n(GitHub OIDC)")
        roles = IAMRole("IAM roles\nadmin · developer · readonly\nci-ecr-push · tf-plan · tf-apply")
        dns = Route53("Route 53")
        cert = ACM("ACM certificate")
        waf = WAF("WAF")
        ecr = ECR("ECR\nsigned images")
        secrets = SecretsManager("Secrets Manager")
        kms = KMS("KMS keys")
        logs = Cloudwatch("CloudWatch\nlogs + metrics")
        trail = Cloudtrail("CloudTrail")
        guard = Guardduty("GuardDuty\nEKS runtime")
        state = S3("S3 Terraform state\n(versioned, locked)")

        with Cluster("VPC 10.20.0.0/16  ·  3 Availability Zones", graph_attr=VPC_STYLE):
            with Cluster("Public subnets", graph_attr=PUBLIC):
                alb = ALB("Application\nLoad Balancer")
                nat = NATGateway("NAT gateway")
            with Cluster("Private subnets", graph_attr=PRIVATE):
                endpoints = Endpoint("VPC endpoints\nECR · S3 · STS · Secrets\nKMS · Logs · EKS Auth")
                with Cluster("Amazon EKS 1.35", graph_attr=EKS_STYLE):
                    eks = EKS("EKS control plane\n(AWS managed)")
                    nodes = EC2("Managed node group\nGraviton (arm64)")
                    argo = ArgoCD("Argo CD")
                    app = Pod("demo-frontend\n→ demo-backend")
                    eso = Pod("External Secrets\n(Pod Identity)")
                    volumes = EBS("EBS gp3\n(encrypted)")

    users >> FLOW("HTTPS", GREEN) >> dns >> waf >> alb >> FLOW("", GREEN) >> app
    cert >> FLOW("TLS", GREEN, "dashed") >> alb
    engineer >> FLOW("SSO", BLUE) >> sso >> roles >> FLOW("EKS access entry", BLUE) >> eks
    actions >> FLOW("OIDC token", BLUE) >> sts >> roles
    actions >> FLOW("push signed image", ORANGE) >> ecr
    actions >> FLOW("plan / apply", PURPLE) >> state
    repo >> FLOW("GitOps pull", ORANGE) >> argo >> FLOW("sync", ORANGE) >> app
    nodes >> FLOW("image pull", ORANGE) >> endpoints >> ecr
    eso >> FLOW("GetSecretValue", RED) >> endpoints >> secrets
    secrets >> FLOW("encrypted by", RED, "dashed") >> kms
    eks >> FLOW("control-plane logs", "#555555", "dashed") >> logs
    nodes >> FLOW("egress", "#555555", "dashed") >> nat
    app >> FLOW("", "#555555", "dotted") >> volumes
    eks - Edge(style="invis") - nodes
    trail - Edge(style="invis") - guard


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
