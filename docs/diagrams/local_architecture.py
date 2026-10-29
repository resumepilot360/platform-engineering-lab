"""Local lab (k3d) architecture diagrams, same style as aws_architecture.py.

Regenerate (needs Graphviz and the `diagrams` package):
    brew install graphviz
    python3 -m venv .venv && .venv/bin/pip install diagrams==0.25.1
    .venv/bin/python docs/diagrams/local_architecture.py

Writes PNGs to docs/images/local/. Tools without an icon in the library
(Cilium, OpenBao, k3d, Kyverno) use the Kubernetes icon for what they run as
(e.g. OpenBao is a StatefulSet), with the tool named in the label.
"""
import importlib.util
from functools import partial
from pathlib import Path

from diagrams import Cluster, Edge
from diagrams.generic.storage import Storage
from diagrams.k8s.compute import STS, Deploy, Job, Pod
from diagrams.k8s.infra import Node
from diagrams.k8s.network import Netpol
from diagrams.k8s.others import CRD
from diagrams.k8s.podconfig import Secret
from diagrams.k8s.rbac import SA
from diagrams.k8s.storage import PV
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.container import K3S, Docker
from diagrams.onprem.dns import Coredns
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.iac import Terraform
from diagrams.onprem.network import Nginx, Traefik
from diagrams.onprem.vcs import Github
from diagrams.k8s.ecosystem import Helm

_spec = importlib.util.spec_from_file_location("_style", Path(__file__).with_name("_style.py"))
_style = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_style)
CLUSTER, GREEN, BLUE, ORANGE, RED, PURPLE = (_style.CLUSTER, _style.GREEN, _style.BLUE,
                                             _style.ORANGE, _style.RED, _style.PURPLE)

OUT = Path(__file__).resolve().parent.parent / "images" / "local"
OUT.mkdir(parents=True, exist_ok=True)
diagram = partial(_style.diagram, OUT)

# Compact layouts with 26pt text: legible after GitHub scales images to page width.
COMPACT = {"fontsize": "44", "nodesep": "1.2", "ranksep": "0.9", "pad": "0.9", "dpi": "96"}
BOLD = {"fontsize": "26", "fontname": "Helvetica Bold"}
BOX = lambda bg, border: {**CLUSTER(bg, border), "fontsize": "30", "margin": "18"}
FLOW = lambda label, color="#3b4a5a", style="solid": Edge(
    label=f" {label} " if label else "", color=color, fontcolor=color, style=style,
    penwidth="3.5", fontsize="26", fontname="Helvetica Bold")
GREY = "#555555"

GITHUB = BOX("#f6f8fa", "#24292f")
HOST = BOX("#f7f9fa", "#232f3e")
CLUSTER_BOX = BOX("#eef4fb", "#326ce5")      # Kubernetes blue
SYSTEM = BOX("#ffffff", "#8c8c8c")
PLATFORM = BOX("#fdf1e6", "#ed7100")
APPS = BOX("#f2f8ea", "#7aa116")
SECRETS = BOX("#fdecee", "#c7131f")


# 1. Components ---------------------------------------------------------------
with diagram("local-components", "Platform Lab (local): components", direction="TB",
             graph=COMPACT, node=BOLD):
    you = Users("You\n(browser · kubectl)")
    with Cluster("GitHub (public repo)", graph_attr=GITHUB):
        repo = Github("Git repo")
        actions = GithubActions("Actions CI")
        ghcr = Storage("GHCR\nimages")

    with Cluster("macOS (Apple Silicon) · Docker Desktop", graph_attr=HOST):
        lb = Nginx("k3d load balancer\n127.0.0.1:6550 · 8081")
        with Cluster("Registries (outlive the cluster)", graph_attr=SYSTEM):
            local_reg = Storage("Local registry\n:5001")
            caches = Storage("Pull-through\ncaches")

        with Cluster("k3d cluster platform-lab · K3s v1.35 · 1 server + 2 agents", graph_attr=CLUSTER_BOX):
            k3s = K3S("API server\nSQLite · secretbox\naudit log")
            agents = Node("2 agent nodes")
            with Cluster("kube-system", graph_attr=SYSTEM):
                cilium = Netpol("Cilium CNI\n+ Hubble")
                traefik = Traefik("Traefik ingress")
                dns = Coredns("CoreDNS")
                storage = PV("local-path\nstorage")
            with Cluster("Platform", graph_attr=PLATFORM):
                argo = ArgoCD("Argo CD")
                eso = Deploy("External\nSecrets")
                bao = STS("OpenBao")
                portal = Pod("Lab portal")
            with Cluster("demo-dev · demo-staging · demo-prod", graph_attr=APPS):
                frontend = Pod("demo-frontend")
                backend = Pod("demo-backend")
                secret = Secret("DB secret")

    you >> FLOW("HTTP / API", GREEN) >> lb >> FLOW("", GREEN) >> traefik
    traefik >> FLOW("", GREEN) >> frontend >> FLOW("", GREEN) >> backend
    traefik >> FLOW("", GREEN, "dashed") >> portal
    actions >> FLOW("push", ORANGE) >> ghcr
    actions >> FLOW("pin digest", ORANGE) >> repo
    repo >> FLOW("GitOps pull", ORANGE) >> argo >> FLOW("sync", ORANGE) >> frontend
    ghcr >> FLOW("", ORANGE, "dashed") >> caches >> FLOW("image pull", ORANGE, "dashed") >> agents
    eso >> FLOW("k8s auth", RED) >> bao
    eso >> FLOW("writes", RED) >> secret >> FLOW("mount", RED) >> backend
    lb >> FLOW("", GREY, "dashed") >> k3s


# 2. GitOps flow --------------------------------------------------------------
with diagram("local-gitops-flow", "Delivery: commit → CI → Git → Argo CD → dev / staging / prod",
             graph={"fontsize": "40", "nodesep": "1.0", "ranksep": "1.1", "dpi": "96"}, node=BOLD):
    dev = Users("Developer")
    reviewer = Users("Reviewer\n(production approval)")
    with Cluster("GitHub", graph_attr=GITHUB):
        repo = Github("main")
        ci = GithubActions("ci: tests · govulncheck\nSemgrep · build · Trivy")
        promote = GithubActions("promote: PR\n(digests only)")
        ghcr = Storage("GHCR")
    with Cluster("k3d cluster", graph_attr=CLUSTER_BOX):
        argo = ArgoCD("Argo CD")
        with Cluster("demo-dev (auto-sync)", graph_attr=APPS):
            d = Pod("apps")
            dh = Job("smoke test")
        with Cluster("demo-staging (auto-sync)", graph_attr=APPS):
            s = Pod("apps")
        with Cluster("demo-prod (manual sync)", graph_attr=PLATFORM):
            p = Pod("apps")

    dev >> FLOW("1 merge") >> repo >> FLOW("2 trigger") >> ci
    ci >> FLOW("3 push", ORANGE) >> ghcr
    ci >> FLOW("4 pin dev digest", ORANGE) >> repo
    repo >> FLOW("5 pull", ORANGE) >> argo >> FLOW("6 sync", ORANGE) >> d >> FLOW("7 PostSync", GREEN) >> dh
    dev >> FLOW("promote", PURPLE, "dashed") >> promote >> FLOW("PR", PURPLE, "dashed") >> repo
    argo >> FLOW("staging", ORANGE) >> s
    reviewer >> FLOW("approve + manual sync", PURPLE) >> argo
    argo >> FLOW("prod", PURPLE) >> p
    dh >> FLOW("fails → git revert (12 s)", RED, "dashed") >> repo


# 3. Secrets flow -------------------------------------------------------------
with diagram("local-secrets", "Secrets: OpenBao → External Secrets → pod",
             graph={"fontsize": "40", "nodesep": "1.0", "ranksep": "1.2", "dpi": "96"}, node=BOLD):
    operator = Users("Operator\nrotate-secret.sh")
    with Cluster("namespace openbao", graph_attr=SECRETS):
        bao = STS("OpenBao\nkv-dev · kv-staging · kv-prod\npolicy + role per env\naudit (HMAC'd)")
    with Cluster("namespace external-secrets", graph_attr=PLATFORM):
        eso = Deploy("ESO controller")
    with Cluster("namespace demo-dev (one per environment)", graph_attr=APPS):
        sa = SA("eso-reader\n(no K8s permissions)")
        store = CRD("SecretStore")
        es = CRD("ExternalSecret\nrefresh 1m")
        secret = Secret("Secret\ndemo-backend-db")
        pod = Pod("demo-backend\nread-only volume")
    k3s = K3S("K3s datastore\nsecretbox encryption")

    operator >> FLOW("HTTP API\n(scoped token)", PURPLE) >> bao
    eso >> FLOW("token (aud openbao)", BLUE) >> sa
    eso >> FLOW("login + read", RED) >> bao
    store >> FLOW("", GREY, "dashed") >> eso
    es >> FLOW("", GREY, "dashed") >> eso
    eso >> FLOW("writes", RED) >> secret >> FLOW("mount", RED) >> pod
    secret >> FLOW("at rest", RED, "dashed") >> k3s


# 4. Ownership ----------------------------------------------------------------
with diagram("local-ownership", "Ownership: one owner per resource", direction="TB",
             graph={"fontsize": "40", "nodesep": "2.4", "ranksep": "1.1", "pad": "0.9", "dpi": "96"},
             node=BOLD):
    tf = Terraform("Terraform\n(AWS only, Phase 8)")
    boot = Helm("Bootstrap\ncluster-up.sh")
    ci = GithubActions("GitHub Actions")
    with Cluster("Argo CD (from Git)", graph_attr={**PLATFORM, "margin": "30"}):
        plat = ArgoCD("platform\nRBAC · stores")
        demo = ArgoCD("demo\nworkloads")
    tf >> FLOW("replaces on AWS", GREY, "dashed") >> boot
    boot >> FLOW("installs", ORANGE) >> plat
    boot >> FLOW("installs", ORANGE) >> demo
    ci >> FLOW("image digests", PURPLE) >> demo

print("\n".join(sorted(p.name for p in OUT.glob("*.png"))))
