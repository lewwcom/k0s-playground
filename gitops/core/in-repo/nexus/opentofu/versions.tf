terraform {
  required_version = ">= 1.6.0"

  required_providers {
    sonatyperepo = {
      source  = "sonatype-nexus-community/sonatyperepo"
      version = ">= 1.18.0"
    }
  }
}
