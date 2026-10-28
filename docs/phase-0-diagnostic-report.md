# Phase 0 — Environment Discovery and Recovery Plan

Date: 2026-10-28 · Scope: read-only inspection, no changes made to Docker, k3d, kubeconfig, or cluster data.

## 1. Host and tooling

| Item | Observed |
|---|---|
| Host | Apple M3 Pro, 11 cores, 18 GiB RAM, macOS 15.6 (arm64) |
| Disk | 42 GiB free on `/` |
| Docker Desktop | Engine 28.5.1, **6 vCPU / 15.1 GiB** allocated, overlayfs |
| Docker disk | 86 volumes, 8.2 GB (7.1 GB reclaimable — not pruned) |
| Other containers | two unrelated project containers on host :8080 and :8000 — **ports to avoid** |
| k3d | v5.9.0 |
| kind | v0.30.0, no clusters |
| kubectl | v1.37.1 — **two minor versions ahead of K3s v1.35** (outside the supported ±1 skew) |
| helm | v4.0.4 |
| terraform | v1.10.1 |
| argocd CLI | v2.12.0 (old; upgrade alongside Argo CD install) |
| semgrep | 1.118.0 |
| Missing | k9s, kustomize (kubectl built-in is available), yq, trivy, syft, cosign, kyverno CLI, vault |

## 2. Kubeconfig

- `KUBECONFIG` unset → `~/.kube/config` is in use. Current context `k3d-dev-cluster` → `https://0.0.0.0:54865`.
- Stale context `kind-kind` (namespace `dev`) points to a kind cluster that no longer exists.
- A separate kubeconfig for another, unrelated project exists in `~/.kube/` — not touched, unrelated to this lab.

## 3. Cluster `dev-cluster` — confirmed facts

Topology: 3 servers (embedded etcd, `server-0` started with `--cluster-init`), 2 agents, 1 serverlb.

| Node | Current IP | IP in etcd membership | Restarts | OOM | k3s process |
|---|---|---|---|---|---|
| server-0 | 172.21.0.3 | 172.21.0.3 | 1 | no | **not running** |
| server-1 | 172.21.0.6 | **172.21.0.4** | 0 | no | **not running** |
| server-2 | 172.21.0.2 | **172.21.0.5** | 0 | no | **not running** |
| agent-0 | 172.21.0.7 | — | 0 | no | running, can't reach API |
| agent-1 | 172.21.0.5 | — | 2 | no | running, can't fetch CA certs |

Timeline (UTC):

1. ~03:59 — cluster created (entrypoint logs `…035916`). No etcd snapshots exist yet (`db/snapshots` empty).
2. 15:57:32 — all six containers start at the same instant, which points to a Docker Desktop or host restart.
3. Docker IPAM assigns new addresses: server-1 `.4 → .6`, server-2 `.5 → .2`, and agent-1 takes `.5`.
4. etcd on every server keeps dialing peer URLs `https://172.21.0.4:2380` and `https://172.21.0.5:2380` (~1,175 failed dials on server-0). `.4` is no longer assigned, and `.5` is now an **agent**, which rejects the TLS handshake. No member can reach another, so pre-vote elections loop at term 3 and **quorum never forms**.
5. With no etcd quorum, the apiserver returns `503 runtime core not ready`. This is the 503 you saw earlier.
6. 16:12:35 — k3s on server-1 and server-2 stops itself: `failed to wait for API server to become ready: context deadline exceeded`. server-0's container restarts (16:12:46), comes up into the same state, and its etcd exits at 16:32:42.
7. Now: on all three servers, k3s has exited. The k3d entrypoint is stuck in its `until kubectl uncordon …; sleep 3` loop, which runs *before* `wait $k3s_pid`. So the containers report **Up**, but nothing is serving. This explains the ~1–50 MiB memory per server and `readyz` returning connection refused.

## 4. Root cause

**Confirmed: etcd peer URLs are tied to container IPs, and Docker reassigned those IPs after the restart.** The cluster lost quorum because two of three members are advertised at addresses that are now wrong.

This was not caused by resources: there were no OOM kills, host memory and disk are healthy, and CPU is idle.

Contributing factor: the k3d entrypoint loop hides the failure. The container stays "Up" after k3s has exited, so `k3d cluster list` reports `3/3` servers.

## 5. Workloads and data at risk

- The API is down, so this was inspected via `crictl` on the agents. The only pod found is `svclb-traefik` (CrashLoopBackOff). The only images are `klipper-lb` and `pause`. **No application workloads or PVC-backed data were found on the agents.**
- etcd data is still on disk: server-0 132 MB, server-1/2 65 MB each (anonymous volumes mounted at `/var/lib/rancher/k3s`).
- Unresolved: I could not list server-side pods or API objects such as namespaces, Secrets and PVCs, because the API is down. If you created anything by hand in the ~12 hours before the restart, it exists only in this etcd data.

## 6. Options

### A. Recover `dev-cluster` (possible, but involves destructive steps)
1. Back up `/var/lib/rancher/k3s/server/db` from all three servers (`docker cp`).
2. On server-0, run `k3s server --cluster-reset` to turn it into a single-member etcd that keeps its data.
3. Wipe the etcd directories on server-1/2 and rejoin them.

Steps 2 and 3 delete etcd data on two members, so they need your approval. **They also don't fix the underlying problem:** the next Docker Desktop restart can reassign IPs and break the cluster again. A k3d multi-server cluster with embedded etcd on Docker's dynamic IPAM is fragile by design.

### B. Build a separate, reproducible lab cluster (recommended)
Leave `dev-cluster` **stopped, not deleted** (`k3d cluster stop dev-cluster` frees CPU/RAM and is reversible). It can serve as the "etcd quorum failure" exercise in Phase 7, since it is a real, already-reproduced incident.

## 7. Proposed lab cluster design (needs approval)

| Decision | Proposal | Rationale |
|---|---|---|
| Name | `platform-lab` (context `k3d-platform-lab`) | Avoids collisions with `dev-cluster` |
| Definition | `local/k3d/platform-lab.yaml` (k3d `Simple` config v1alpha5), created by script | Reproducible from Git |
| Topology | **1 server + 2 agents** | No multi-member etcd, so it survives Docker restarts. Agents still give real scheduling, taints and spread |
| Datastore | K3s default (SQLite via kine) on the single server | Stable on restart. HA etcd is covered in Phase 7 with a disposable 3-server cluster |
| K3s image | `rancher/k3s:v1.35.5-k3s1` (pinned) | Matches your current version |
| API port | `127.0.0.1:6550` (fixed, loopback only) | Predictable kubeconfig; not exposed on the LAN |
| Ingress | Keep bundled Traefik, mapped to host `127.0.0.1:8081/8443`, using Ingress *and* Gateway API | :8080 is already taken. ingress-nginx was retired upstream (March 2026), so it isn't recommended for new builds. On AWS the equivalent is the AWS Load Balancer Controller (ALB) |
| Registry | k3d-managed registry `k3d-registry.localhost:5001` | Local push/pull, and tests the "approved registries" policy |
| Storage | Bundled `local-path` provisioner, documented as node-local (not EBS-equivalent) | Lightweight; limitations documented |
| CNI | **Decision needed:** keep flannel + K3s embedded NetworkPolicy controller, or replace with Calico/Cilium | Flannel + kube-router enforces NetworkPolicy but has no egress FQDN/L7. Cilium is closer to production but uses ~1 GiB more RAM |
| Metrics Server | Bundled K3s one | Already included |
| Audit logging | API server audit policy file mounted via k3d `volumes` + `--kube-apiserver-arg` | Needed for Phase 2 |
| kubectl | Install v1.35.x client (e.g. via `asdf`/direct binary) or document skew | Removes the version-skew warning |

## 8. Resource budget

Docker currently has 6 vCPU and 15.1 GiB, out of 18 GiB on the host. That leaves only ~3 GiB for macOS, so **don't increase it**.

| Stack | Approx RAM |
|---|---|
| K3s 1 server + 2 agents | 1.5 GiB |
| Ingress, registry, metrics | 0.4 GiB |
| Argo CD (non-HA) | 0.8 GiB |
| Kyverno (1 replica each) | 0.5 GiB |
| Vault dev or ESO + fake provider | 0.2–0.3 GiB |
| kube-prometheus-stack (trimmed) + Loki single-binary | 2.5–3 GiB |
| Falco (optional, Phase 5) | 0.3–0.5 GiB |
| **Total at full build-out** | **~6.5–7.5 GiB** |

This fits only if `dev-cluster` stays stopped and observability is trimmed (short retention, no node-exporter duplication).

## 9. Risks

1. Docker Desktop restarts: they don't affect a single-server cluster, but the scripts will include a health-check and a "restart lab" step.
2. Memory pressure in Phase 7: mitigated with trimmed Helm values and on-demand components.
3. Falco on Docker Desktop (LinuxKit kernel): the modern eBPF driver *should* work but is not guaranteed. Will be verified before committing to it.
4. Local stand-ins are **not** AWS IAM, KMS or ALB. Every phase will document the gap.

## 10. Implementation sequence

Phase 1 (foundation) → 2 (IAM/RBAC + audit) → 3 (secrets) → 4 (GitOps) → 5 (DevSecOps, minimum stack chosen after the trade-off review) → 6 (network) → 7 (observability + incident drills) → 8 (Terraform design only, no `apply` without approval).

## 11. Decisions requested

1. Leave `dev-cluster` stopped and preserved (B), or attempt recovery (A)?
2. CNI: flannel (lighter) or Cilium (more realistic, +~1 GiB)?
3. Ingress: bundled Traefik (recommended) or Envoy Gateway (Gateway API only)?
4. Initialize this directory as a Git repository (and create a GitHub remote now or later)?
