# ADR-0001: Single-server k3d topology with SQLite datastore

- Status: Accepted (2026-10-28)
- Context: Phase 0 found `dev-cluster` (3 servers, embedded etcd) had lost quorum.
  Docker Desktop reassigned container IPs after a restart, and etcd peer URLs are
  bound to those IPs (docs/phase-0-diagnostic-report.md).

## Decision
`platform-lab` runs **1 server + 2 agents** on K3s' default SQLite (kine)
datastore. No `--cluster-init`. Neither `network:` nor `subnet:` is set in the
k3d config:
- `network:` means "join an existing network".
- `subnet:` turns on k3d's static IPAM. On create, that collided with the
  pre-attached registry container ("Address already in use").

## Consequences
- Survives container IP changes: no peers to lose. Verified with `k3d cluster stop/start`.
- No control-plane HA. If the server is lost, the API is unavailable (workloads
  on agents keep running). This is acceptable for a lab.
- etcd quorum behaviour is **not** exercised here. Phase 7 uses a separate,
  disposable 3-server cluster (or the preserved `dev-cluster`) for that drill.
- AWS gap: EKS runs a managed, multi-AZ control plane, so there is no datastore for us to operate.
