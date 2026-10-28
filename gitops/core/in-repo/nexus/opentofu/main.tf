# Active Security Realms
resource "sonatyperepo_security_realms" "realms" {
  active = var.active_realms
}

# OCI Proxy Repositories (named after upstream registry domains)
resource "sonatyperepo_repository_oci_proxy" "oci_proxies" {
  for_each = var.oci_proxies

  name   = each.key
  online = true

  oci = {
    force_basic_auth = false
    v1_enabled       = true
    path_enabled     = true
  }

  oci_proxy = {}

  storage = {
    blob_store_name                = var.blob_store_name
    strict_content_type_validation = true
  }

  proxy = {
    remote_url = each.value.remote_url
  }

  negative_cache = {}

  http_client = {
    blocked    = false
    auto_block = true
  }
}
