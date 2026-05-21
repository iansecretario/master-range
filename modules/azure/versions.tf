terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
      # `azurerm.dns` is the aliased provider used by frontdoor.tf for
      # the DNS zone + records. Defaults to the same subscription as
      # the deployment, but the env can override to a different sub
      # when the registered domain lives in a separate Azure tenant.
      # `azurerm.guac_dns` is the same idea but for the operator-facing
      # Guacamole custom hostname (typically a different domain than
      # the C2 fronting one, often in a different subscription too).
      configuration_aliases = [azurerm.dns, azurerm.guac_dns]
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
