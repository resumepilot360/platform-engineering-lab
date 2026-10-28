# ADR-0004: Standalone local registry with mirrored, pinned images

- Status: Accepted (2026-10-28)

## Decision
Create `k3d-registry.localhost` (`127.0.0.1:5001`) *outside* the cluster
lifecycle and attach it with `registries.use`. `scripts/seed-registry.sh`
mirrors pinned upstream images into `lab/*`. Workloads reference
`k3d-registry.localhost:5001/...`.

## Why
- Images survive `cluster-down --delete` and rebuilds.
- A single approved source makes the Phase 5 "unapproved registries" policy meaningful.
- Stands in for ECR.

## Consequences / known gaps
- The registry is plain HTTP with no auth. Acceptable on loopback; never expose it.
- ~~K3s system images still come from Docker Hub/quay.io on every rebuild.~~
  **Resolved (2026-10-28, Phase 3):** three pull-through caches
  (`k3d-mirror-{quay,dockerhub,ghcr}.localhost`, persistent volumes) are wired
  in as containerd mirrors through `registries.config` in the k3d config.
  Why: a rebuild interrupted by host sleep failed on
  `lookup registry-1.docker.io: no such host`, and a cold rebuild took over 5 min pulling
  Cilium at ~1 MB/s per node. The first pull through each cache is still bound by
  upstream bandwidth; later rebuilds pull locally. If a cache is down, containerd
  falls back to the upstream.
- The caches serve whatever upstream serves. They are a performance and
  availability control, **not** a trust control. Image allow-listing and
  signature checks come in Phase 5.
- AWS: ECR pull-through cache rules for quay.io/Docker Hub/ghcr.io (Docker Hub needs credentials in Secrets Manager); ECR with immutable tags and scan-on-push, pulled by node IAM role. Pull-through cache rules cover upstream registries.
