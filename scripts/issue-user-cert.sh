#!/usr/bin/env bash
# Issue a short-lived x509 client certificate for a human persona via the
# Kubernetes CSR API and write a kubeconfig for it.
#
#   scripts/issue-user-cert.sh <username> <group>[,<group>...] [ttl-seconds]
#
# The username becomes the cert CN and each group an O= entry; that is all the
# API server knows about the identity. Kubernetes cannot revoke client certs,
# so TTLs are short (default 24h). Removing the RBAC binding is the only
# "revocation" before expiry — see docs/iam-model.md.
#
# Private key + kubeconfig land in .tools/identities/ (gitignored, mode 600).
source "$(dirname "$0")/lib.sh"

user="${1:?username}"; groups="${2:?group list}"; ttl="${3:-86400}"
[[ "$user" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "username must be lowercase alnum/dash"
dir="$LAB_ROOT/.tools/identities"; mkdir -p "$dir"; chmod 700 "$dir"
key="$dir/$user.key"; crt="$dir/$user.crt"; cfg="$dir/$user.kubeconfig"
csr_name="lab-user-$user-$(date +%s)"

subj="/CN=$user"; IFS=, read -ra gs <<<"$groups"; for g in "${gs[@]}"; do subj+="/O=$g"; done
( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$key" 2>/dev/null )
csr_pem=$(openssl req -new -key "$key" -subj "$subj" 2>/dev/null | base64 | tr -d '\n')

kc apply -f - >/dev/null <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $csr_name
  labels: {lab.platform/persona: "$user"}
spec:
  request: $csr_pem
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $ttl
  usages: ["client auth"]
YAML
kc certificate approve "$csr_name" >/dev/null
for _ in $(seq 1 20); do
  cert=$(kc get csr "$csr_name" -o jsonpath='{.status.certificate}'); [[ -n "$cert" ]] && break; sleep 1
done
[[ -n "${cert:-}" ]] || die "CSR $csr_name was approved but not signed"
echo "$cert" | base64 -d > "$crt"
kc delete csr "$csr_name" >/dev/null     # CSR objects are not needed after issuance

server=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$KUBE_CONTEXT')].cluster.server}")
kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$KUBE_CONTEXT')].cluster.certificate-authority-data}" \
  | base64 -d > "$dir/cluster-ca.crt"
rm -f "$cfg"
KUBECONFIG="$cfg" kubectl config set-cluster "$CLUSTER_NAME" --server="$server" \
  --certificate-authority="$dir/cluster-ca.crt" --embed-certs >/dev/null
KUBECONFIG="$cfg" kubectl config set-credentials "$user" --client-certificate="$crt" \
  --client-key="$key" --embed-certs >/dev/null
KUBECONFIG="$cfg" kubectl config set-context "$user@$CLUSTER_NAME" --cluster="$CLUSTER_NAME" --user="$user" >/dev/null
KUBECONFIG="$cfg" kubectl config use-context "$user@$CLUSTER_NAME" >/dev/null
chmod 600 "$cfg" "$key" "$crt"

log "Issued $user ($groups), expires $(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
log "Use: KUBECONFIG=$cfg kubectl auth whoami"
