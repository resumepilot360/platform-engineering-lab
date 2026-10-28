# ADR-0006: Namespace baseline — restricted Pod Security, LimitRange, ResourceQuota

- Status: Accepted (2026-10-28)

## Decision
Every workload namespace (`demo-dev`, `demo-staging`, `lab-smoke`) gets:
- Pod Security Admission `enforce=restricted`, plus `warn` and `audit` at the same level.
- A LimitRange that injects default requests/limits and caps any single container at 1 CPU / 1 GiB.
- A ResourceQuota: 1 CPU / 1 GiB requests, 2 / 2 GiB limits, 20 pods, 5 PVCs.
  It also sets `services.nodeports=0` and `services.loadbalancers=0`, so apps can
  only be exposed through Ingress.

## Why
These are built-in controls available before Kyverno (Phase 5). PSA alone
covers privileged containers, root, host networking and hostPath. Kyverno later
adds what PSA cannot express: registries, signatures, labels, and limits being *set* rather than defaulted.

## Consequences
- Third-party charts must run in their own namespaces or meet the restricted profile.
- kube-system is exempt (K3s default). Cilium needs privileged access by design.
