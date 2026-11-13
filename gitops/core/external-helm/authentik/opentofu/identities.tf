resource "authentik_group" "acme_local" {
  name = "acme.local"
}

resource "authentik_group" "developer" {
  name    = "developer"
  parents = [authentik_group.acme_local.id]
}

resource "authentik_user" "john_doe" {
  username = "john.doe"
  name     = "John Doe"
  email    = "john.doe@acme.local"
  groups   = [authentik_group.developer.id]
}
