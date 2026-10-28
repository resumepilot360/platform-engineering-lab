# ESO in namespace demo-dev: read-only, dev mount only.
path "kv-dev/data/demo/*" {
  capabilities = ["read"]
}
