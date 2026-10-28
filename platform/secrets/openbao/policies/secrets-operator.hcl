# Human/automation token used for seeding and rotation. Writes app secrets;
# cannot change policies, auth methods, mounts or audit devices.
path "kv-dev/data/demo/*"         { capabilities = ["create", "read", "update"] }
path "kv-dev/metadata/demo/*"     { capabilities = ["read", "list"] }
path "kv-staging/data/demo/*"     { capabilities = ["create", "read", "update"] }
path "kv-staging/metadata/demo/*" { capabilities = ["read", "list"] }
path "kv-prod/data/demo/*"        { capabilities = ["create", "read", "update"] }
path "kv-prod/metadata/demo/*"    { capabilities = ["read", "list"] }
