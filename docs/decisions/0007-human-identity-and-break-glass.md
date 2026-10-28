# ADR-0007: Short-lived x509 personas, group-based RBAC, impersonation break-glass

- Status: Accepted (2026-10-28)

## Context
Phase 2 needs real (not just simulated) authentication for admin, developer and
read-only personas, plus restricted privileged access. Options considered:

| Option | Pros | Cons |
|---|---|---|
| `--as` impersonation only | Zero setup | Tests authorization only, never authentication |
| **x509 via CSR API** | Real authN; built in; TTL via `expirationSeconds` | Not revocable; key files on disk |
| Dex + kubelogin (OIDC) | Closest to production SSO | TLS issuer, API server config, browser flow; more moving parts |

## Decision
- Issue x509 certs through `certificates.k8s.io/v1` (`scripts/issue-user-cert.sh`) with a 24h TTL.
  Keys and kubeconfigs live in `.tools/identities/` (gitignored, 0600).
- Bind RBAC only to **groups**, never to individual users.
- Admins never hold cluster-admin. Elevation is impersonation of a single
  pinned identity (`break-glass` / `lab:break-glass`), recorded in the audit log.
- OIDC (Dex) is deferred to an optional Phase 2b.

## Consequences
- See docs/iam-model.md §4 for the limitations this accepts: no revocation,
  root bootstrap credential, pod-create ⇒ ServiceAccount use.
- The persona model carries over to EKS: groups become access-entry
  `kubernetes_groups`, and break-glass becomes an MFA-gated IAM role.
