variable "nexus_url" {
  description = "Base URL of the Sonatype Nexus instance"
  type        = string
  default     = "http://nexus.k0s.localhost:30080"
}

variable "nexus_username" {
  description = "Administrator username for Nexus"
  type        = string
  default     = "admin"
}

variable "nexus_password" {
  description = "Administrator password for Nexus"
  type        = string
  sensitive   = true
  default     = "password"
}

variable "blob_store_name" {
  description = "Blob store name for proxy repositories"
  type        = string
  default     = "default"
}

variable "active_realms" {
  description = "List of active security realms in Nexus"
  type        = list(string)
  default = [
    "NexusAuthenticatingRealm",
    "DockerToken",
    "OciBearerToken"
  ]
}

variable "oci_proxies" {
  description = "Map of OCI proxy repositories named matching upstream registry domain"
  type = map(object({
    remote_url = string
  }))
  default = {
    "docker.io" = {
      remote_url = "https://registry-1.docker.io"
    }
    "quay.io" = {
      remote_url = "https://quay.io"
    }
    "ghcr.io" = {
      remote_url = "https://ghcr.io"
    }
    "registry.k8s.io" = {
      remote_url = "https://registry.k8s.io"
    }
    "cr.kgateway.dev" = {
      remote_url = "https://cr.kgateway.dev"
    }
    "public.ecr.aws" = {
      remote_url = "https://public.ecr.aws"
    }
  }
}
