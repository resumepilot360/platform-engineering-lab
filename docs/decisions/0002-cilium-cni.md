# ADR-0002: Cilium as CNI, kube-proxy retained

- Status: Accepted (2026-10-28)

## Decision
Disable flannel (`--flannel-backend=none`) and the K3s kube-router policy
controller (`--disable-network-policy`). Install Cilium (chart pinned in
`local/versions.env`) with:
- `ipam.mode=kubernetes`: uses the podCIDRs K3s allocates.
- VXLAN tunnelling.
- `kubeProxyReplacement=false`: K3s kube-proxy still handles Services.
- Hubble relay on, UI off.

## Why
- Enforces Kubernetes NetworkPolicy *and* CiliumNetworkPolicy (L7, FQDN-based
  egress), which Phase 6 needs. Hubble gives flow logs for allowed/denied
  evidence in Phases 6–7.
- Keeping kube-proxy avoids pinning `k8sServiceHost` to a container hostname and
  keeps one less moving part. Kube-proxy replacement can be revisited later.

## Consequences
- ~0.7 GiB extra RAM across 3 nodes vs flannel.
- No hostPort support without kube-proxy replacement → servicelb is disabled
  and Traefik uses NodePort (ADR-0003).
- Works on the Docker Desktop LinuxKit kernel with chart defaults (bpffs/cgroup
  auto-mount). No manual node prep was needed.
- AWS gap: EKS defaults to the Amazon VPC CNI (pods get VPC IPs and
  security groups for pods). Cilium on EKS would run in ENI or chaining mode. Policy
  semantics carry over; IP addressing and SG integration do not.
