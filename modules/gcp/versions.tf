terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
      # `google.dns` is the aliased provider used by cdn.tf for the
      # Cloud DNS zone + records. Defaults to the same project as the
      # deployment, but the env can override to a different project
      # when the registered domain lives in a separate GCP project
      # (or a separate org's project, via terraform's provider
      # configuration_aliases).
      # `google.guac_dns` mirrors azurerm.guac_dns — same idea but
      # scoped to the operator-facing Guacamole custom hostname,
      # typically a different domain (and often a different project)
      # than the C2 fronting one.
      configuration_aliases = [google.dns, google.guac_dns]
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
      # google-beta is required for several IAP + Cloud Armor + ACME-
      # cert lifecycle features that haven't graduated to GA. We
      # bind it the same way (aliased for cross-project DNS).
      configuration_aliases = [google-beta.dns, google-beta.guac_dns]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
