# Runbook: platform-lab cluster lifecycle

All scripts pin `--context k3d-platform-lab`; they never act on `dev-cluster`.

| Task | Command | Expected |
|---|---|---|
| Install tools | `scripts/install-tools.sh` | kubectl v1.35.10 in `.tools/bin`, other tools via brew |
| Preflight | `scripts/preflight.sh` | `N passed, 0 failed` |
| Create / converge | `scripts/cluster-up.sh` | ends with health-check `14 passed, 0 failed` (~2–4 min on a warm cache) |
| Health | `scripts/health-check.sh` | 14 PASS |
| Phase 1 acceptance | `tests/phase1/acceptance.sh` | all PASS; log in `reports/` |
| Stop (keeps state) | `scripts/cluster-down.sh` | containers Exited |
| Start | `scripts/cluster-up.sh` (or `k3d cluster start platform-lab`) | health PASS |
| Delete | `scripts/cluster-down.sh --delete` (type the name) | registry + images kept |
| Use kubectl | `export PATH=$PWD/.tools/bin:$PATH; kubectl --context k3d-platform-lab get nodes` | 3 Ready |
| UI | `k9s --context k3d-platform-lab` | |

## Rollback
Phase 1 has no in-place upgrades. Rollback means `cluster-down.sh --delete`
followed by `cluster-up.sh` from the previous Git commit. The registry and
mirrored images persist. Workload data in local-path PVCs is **lost** on delete.

## Troubleshooting

### Pods stuck in ContainerCreating / ImagePullBackOff after host sleep or a network change
Evidence: events show `dial tcp: lookup registry-1.docker.io: no such host`, or
a pull that never finishes. Seen 2026-10-28 when the Mac slept mid-rebuild.
```
kubectl --context k3d-platform-lab -n kube-system get events --sort-by=.lastTimestamp | grep -v Normal
docker exec k3d-platform-lab-agent-0 nslookup registry-1.docker.io   # DNS recovered?
kubectl --context k3d-platform-lab -n kube-system delete pod --field-selector=status.phase=Pending
scripts/cluster-up.sh   # idempotent
```

### `helm upgrade` complains about another operation in progress
An interrupted install leaves the release in `pending-install`. A release in
`failed` state can simply be re-run with `cluster-up.sh`. For pending:
`helm --kube-context k3d-platform-lab -n kube-system history cilium`, then
`helm ... rollback cilium <rev>` (or uninstall if revision 1 never completed).

### k3d create fails: "cannot specify subnet for existing network" / "Address already in use"
Don't set `network:` or `subnet:` in `local/k3d/platform-lab.yaml` (ADR-0001). Remove
the leftover network from the failed attempt:
`docker network disconnect k3d-platform-lab k3d-registry.localhost; docker network rm k3d-platform-lab`.

### Ingress returns connection refused on :8081
`docker ps --filter name=k3d-platform-lab-serverlb` should show `127.0.0.1:8081->30080`.
`kubectl -n kube-system get svc traefik` should show type NodePort with 80:30080.
If it shows LoadBalancer, the HelmChartConfig mount was missing: check `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` on server-0.

### Node NotReady after create
Expected until Cilium is installed (no CNI). Check `cilium --context k3d-platform-lab status`.

## Docker Desktop restart
The single server has no peers, so IP changes are harmless. Run
`scripts/health-check.sh` afterwards. Not tested by restarting Docker Desktop
itself, because that would interrupt other containers on this host.
