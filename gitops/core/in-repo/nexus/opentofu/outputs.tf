output "oci_proxy_repositories" {
  description = "List of configured OCI proxy repositories"
  value = {
    for k, v in sonatyperepo_repository_oci_proxy.oci_proxies : k => {
      name       = v.name
      remote_url = var.oci_proxies[k].remote_url
    }
  }
}
