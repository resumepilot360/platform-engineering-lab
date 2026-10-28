# Platform Engineering Lab

A reproducible, production-inspired Kubernetes platform built locally with k3d
on Apple Silicon, as groundwork for an AWS (EKS + Terraform) equivalent.
**No AWS resources are created until the AWS phase is explicitly approved.**

## Status

| Phase | Scope | Status |
|---|---|---|
| 0 | Environment discovery | Done — [report](docs/phase-0-diagnostic-report.md) |
| 1 | Local foundation (k3d, Cilium, Traefik, registry, storage, metrics, namespaces) | Done — see `reports/phase1-acceptance.log` |
| 2 | IAM / RBAC / audit | Not started |
| 3 | Secrets | Not started |
| 4 | GitOps (Argo CD + GitHub Actions) | Not started |
| 5 | DevSecOps and policy | Not started |
| 6 | Network security | Not started |
| 7 | Observability and incident response | Not started |
| 8 | Terraform / AWS design | Not started |

## Quick start
```bash
scripts/install-tools.sh      # pinned kubectl into .tools/bin + brew tools
scripts/cluster-up.sh         # registry + cluster + Cilium + namespaces + health check
tests/phase1/acceptance.sh    # Phase 1 acceptance tests
export PATH=$PWD/.tools/bin:$PATH
kubectl --context k3d-platform-lab get nodes
curl http://smoke.lab.localhost:8081/
```

## Local endpoints (loopback only)
| Endpoint | Purpose |
|---|---|
| `https://127.0.0.1:6550` | Kubernetes API (context `k3d-platform-lab`) |
| `http://*.lab.localhost:8081`, `https://*.lab.localhost:8443` | Traefik ingress |
| `localhost:5001` (host) / `k3d-registry.localhost:5001` (cluster) | Image registry |

## Layout
- `local/`: k3d cluster definition, pinned versions, node-level config (audit policy, Traefik overrides)
- `platform/`: cluster platform config (namespaces, networking, then RBAC, policies, secrets, observability)
- `tests/`: per-phase acceptance tests
- `scripts/`: preflight, bootstrap, validation, health
- `docs/`: diagnostic report, [decisions](docs/decisions/), [runbooks](docs/runbooks/)

Versions are pinned in [`local/versions.env`](local/versions.env).
The existing `dev-cluster` is stopped and preserved. See the Phase 0 report.
