################################################################################
# envs/shared-guac-azure — persistent shared Guacamole deployment.
#
# This env dir has its OWN terraform state, independent of any
# envs/azure/, envs/aws/, envs/inst-NN-* deploy. The shared Guac it
# stands up serves every range that registers connections into it.
#
# Lifecycle:
#   terraform apply  ─►  create / converge the shared Guac
#   terraform apply  ─►  no-op on subsequent runs (idempotent)
#   terraform destroy ─►  tear down the shared Guac entirely
#                         (only do this when migrating away — every
#                          deployed range will lose its UI access until
#                          a new shared Guac is brought up + range
#                          applies re-register)
#
# Don't ever `state rm` this — it's the source of truth for the Guac
# the rest of terra-range's range applies (Phase 2B onwards) call into.
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Default provider — same subscription as the Guac itself runs in.
provider "azurerm" {
  features {}
}

# DNS provider alias — pointed at the subscription that owns the DNS
# zone (`cyberwarrange.com` in your case). When the DNS zone lives in
# the same sub as the Guac, the subscription_id below is null (provider
# falls back to the default) — terraform handles that cleanly. When
# different, supply the zone's sub id in terraform.tfvars.json under
# `dns_zone_subscription_id`.
provider "azurerm" {
  alias = "dns"
  features {}
  subscription_id = (
    var.dns_zone_subscription_id != ""
    ? var.dns_zone_subscription_id
    : null
  )
}

# ---- Inputs --------------------------------------------------------------
# Mirrors modules/shared-guac/variables.tf so the operator only edits one
# tfvars file. Defaults match the module's; override per-deploy via
# terraform.tfvars.json.

variable "name" {
  type    = string
  default = "shared-guac"
}
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "vm_size" {
  type    = string
  default = "Standard_B4ms"
}
variable "admin_user" {
  type    = string
  default = "guacadmin"
}
variable "admin_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "login_title" {
  type    = string
  default = "Guidem CWR — Shared Range Portal"
}
variable "operator_username" {
  type    = string
  default = "cwr-ian"
}
variable "ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "acme_email" {
  type    = string
  default = "admin@example.com"
}
variable "custom_hostname" {
  type    = string
  default = "guac"
}
variable "dns_zone_name" {
  type    = string
  default = ""
}
variable "dns_zone_resource_group" {
  type    = string
  default = ""
}
variable "dns_zone_subscription_id" {
  type    = string
  default = ""
}
variable "vnet_cidr" {
  type    = string
  default = "10.250.0.0/22"
}
variable "subnet_cidr" {
  type    = string
  default = "10.250.0.0/24"
}
variable "static_ip" {
  type    = string
  default = "10.250.0.20"
}

# ---- Module call ---------------------------------------------------------
module "shared_guac" {
  source = "../../modules/shared-guac"

  providers = {
    azurerm     = azurerm
    azurerm.dns = azurerm.dns
  }

  name                     = var.name
  azure_region             = var.azure_region
  vm_size                  = var.vm_size
  admin_user               = var.admin_user
  admin_password           = var.admin_password
  login_title              = var.login_title
  operator_username        = var.operator_username
  ingress_cidrs            = var.ingress_cidrs
  acme_email               = var.acme_email
  custom_hostname          = var.custom_hostname
  dns_zone_name            = var.dns_zone_name
  dns_zone_resource_group  = var.dns_zone_resource_group
  dns_zone_subscription_id = var.dns_zone_subscription_id
  vnet_cidr                = var.vnet_cidr
  subnet_cidr              = var.subnet_cidr
  static_ip                = var.static_ip
}

# ---- Outputs -------------------------------------------------------------
# Re-export every module output so `./range guac creds` (and future
# range applies in Phase 2B that read this state via
# `terraform_remote_state` or via `./range guac --json`) can grab the
# values directly.

output "guacamole_url" {
  value = module.shared_guac.guacamole_url
}
output "guacamole_fqdn" {
  value = module.shared_guac.guacamole_fqdn
}
output "guacamole_admin_user" {
  value = module.shared_guac.guacamole_admin_user
}
output "guacamole_admin_password" {
  value     = module.shared_guac.guacamole_admin_password
  sensitive = true
}
output "guacamole_public_ip" {
  value = module.shared_guac.guacamole_public_ip
}
output "guacamole_private_ip" {
  value = module.shared_guac.guacamole_private_ip
}
output "guacamole_vnet_id" {
  value = module.shared_guac.guacamole_vnet_id
}
output "guacamole_vnet_name" {
  value = module.shared_guac.guacamole_vnet_name
}
output "guacamole_resource_group" {
  value = module.shared_guac.guacamole_resource_group
}
output "guacamole_subscription_id" {
  value = module.shared_guac.guacamole_subscription_id
}
