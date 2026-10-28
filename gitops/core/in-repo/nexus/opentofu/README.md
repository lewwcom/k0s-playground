# Nexus OCI Proxy OpenTofu Module

This OpenTofu configuration manages OCI proxy repositories for Sonatype Nexus
Repository Manager.

## Features

- **Format**: Native Nexus OCI format (`sonatyperepo_repository_oci_proxy`),
  supporting container images, Cosign signatures, Helm OCI packages, and OCI 1.1
  referrers.
- **Security Realms**: Enables `DockerToken` realm alongside default
  authentication/authorization realms.
- **OCI Proxy Repositories**: Upstream registries named after their actual
  registry domains for transparent runtime mirroring:
  - `docker.io` -> `https://registry-1.docker.io`
  - `quay.io` -> `https://quay.io`
  - `ghcr.io` -> `https://ghcr.io`
  - `registry.k8s.io` -> `https://registry.k8s.io`
  - `cr.kgateway.dev` -> `https://cr.kgateway.dev`
  - `public.ecr.aws` -> `https://public.ecr.aws`

## Usage

### 1. Configure Variables

Copy the example variable file or use environment variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Or pass via environment:

```bash
export TF_VAR_nexus_url="http://nexus.k0s.localhost:30080"
export TF_VAR_nexus_username="admin"
export TF_VAR_nexus_password="password"
```

### 2. Initialize and Validate

```bash
tofu init
tofu validate
```

### 3. Plan and Apply

```bash
tofu plan
tofu apply
```

