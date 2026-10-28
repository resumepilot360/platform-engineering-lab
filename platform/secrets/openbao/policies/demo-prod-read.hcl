# ESO in namespace demo-prod: read-only, prod mount only.
path "kv-prod/data/demo/*" {
  capabilities = ["read"]
}
