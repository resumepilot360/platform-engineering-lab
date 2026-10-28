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
- **K3s system images (Traefik, CoreDNS, metrics-server, Cilium) still come from
  Docker Hub/quay.io.** A rebuild interrupted by host sleep failed on
  `lookup registry-1.docker.io: no such host` (2026-10-28). Possible future
  mitigations: a pull-through cache, or `k3d image import` of a pre-pulled set.
- AWS: ECR with immutable tags and scan-on-push, pulled by node IAM role. Pull-through cache rules cover upstream registries.
