# ADR-0003: Bundled Traefik, exposed via NodePort through the k3d load balancer

- Status: Accepted (2026-10-28)

## Decision
Keep K3s' bundled Traefik, configured by `local/configuration/traefik-config.yaml`
(HelmChartConfig, mounted into the server's auto-deploy manifests directory):
- Service type NodePort, fixed ports 30080/30443.
- k3d maps `127.0.0.1:8081 → 30080` and `127.0.0.1:8443 → 30443` on the load balancer.

## Why
- ingress-nginx was retired upstream (March 2026), so we don't start new builds on it.
- servicelb (klipper-lb) needs hostPort, which Cilium without kube-proxy replacement doesn't provide.
- Loopback-only bindings keep ingress off the LAN. 8080 was already taken on the host.

## Consequences
- Hostnames under `*.lab.localhost` resolve to 127.0.0.1 in curl and browsers, so no `/etc/hosts` edits.
- The K3s helm-controller owns Traefik's lifecycle. Its version follows the K3s image pin.
- TLS and Gateway API are deferred to Phase 6.
- AWS gap: on EKS, the AWS Load Balancer Controller provisions ALBs/NLBs from
  Ingress/Gateway/Service objects. TLS terminates with ACM certificates.
