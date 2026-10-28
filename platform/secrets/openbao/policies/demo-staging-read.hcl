# ESO in namespace demo-staging: read-only, staging mount only.
path "kv-staging/data/demo/*" {
  capabilities = ["read"]
}
