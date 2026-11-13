variable "authentik_url" {
  description = "Base URL of the Authentik instance"
  type        = string
  default     = "http://authentik.k0s.localhost:30080"
}

variable "authentik_token" {
  description = "API token for Authentik authentication"
  type        = string
  sensitive   = true
  default     = "token"
}

variable "authentik_insecure" {
  description = "Whether to skip TLS certificate verification when connecting to Authentik"
  type        = bool
  default     = false
}

variable "argocd_client_secret" {
  description = "OAuth2 client secret for Argo CD"
  type        = string
  sensitive   = true
  default     = "client-secret"
}
