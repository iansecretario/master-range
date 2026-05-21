terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # Optional remote state — uncomment and configure for team use:
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstateXXX"
  #   container_name       = "tfstate"
  #   key                  = "cyber-range.tfstate"
  # }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Aliased provider for the DNS subscription. When the registered domain
# lives in a different Azure subscription than the range deployment,
# set advanced_c2.dns_zone_subscription_id in the scenario YAML; this
# provider authenticates against that sub for the data-source lookup
# and DNS record writes. When unset, it falls through to the default
# provider's subscription (no-op, behaves like a single-sub deploy).
provider "azurerm" {
  alias           = "dns"
  subscription_id = var.advanced_c2.dns_zone_subscription_id != "" ? var.advanced_c2.dns_zone_subscription_id : null
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Aliased provider for the Guacamole custom-hostname DNS zone. This is
# typically a SEPARATE subscription from the advanced_c2 zone (e.g.,
# the C2 fronting uses enterprisestudio.com in one sub while the
# operator-facing Guacamole portal uses cyberwarrange.com in another).
# When services.guacamole.dns_zone_subscription_id is empty, falls
# through to the default provider's subscription.
provider "azurerm" {
  alias           = "guac_dns"
  subscription_id = var.services.guacamole.dns_zone_subscription_id != "" ? var.services.guacamole.dns_zone_subscription_id : null
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ---- pass-through variables (filled by terraform.tfvars.json) ----
variable "range_name" {
  type = string
}

variable "azure_region" {
  type    = string
  default = "southeastasia"   # Singapore
}

variable "lockdown" {
  type    = bool
  default = false
}

variable "vm_priority" {
  type    = string
  default = "Regular"
  validation {
    condition     = contains(["Regular", "Spot"], var.vm_priority)
    error_message = "vm_priority must be 'Regular' or 'Spot'."
  }
}

variable "guacamole_ingress_cidrs" {
  type = list(string)
}

variable "domain" {
  type = object({
    enabled           = bool
    fqdn              = string
    netbios           = string
    admin_user        = string
    admin_password    = string
    safemode_password = string
    lab_users = optional(list(object({
      name     = string
      password = string
    })), [])
  })
}

variable "students" {
  type = object({
    count       = number
    tenancy     = string
    name_format = string
  })
}

variable "machines" {
  type = list(object({
    name               = string
    base_name          = string
    student_id         = string
    student_index      = number
    role               = string
    os                 = string
    size               = string
    static_ip          = string
    domain_join        = bool
    win_admin_user     = string
    win_admin_password = string
    linux_user         = string
    linux_password     = string
    persona_name       = optional(string, "")
    persona_b64        = optional(string, "")
    fronts             = optional(string, "")
    callsign           = optional(string, "")
    assigned_user      = optional(string, "")
    enable_root_ssh    = optional(bool, false)
  }))
}

variable "student_users" {
  type = list(object({
    student_id = string
    username   = string
    password   = string
  }))
  default = []
}

variable "shared_machines" {
  type = list(object({
    name           = string
    role           = string
    os             = string
    size           = string
    linux_user     = string
    linux_password = string
    public_ip      = optional(bool, true)
  }))
  default = []
}

variable "advanced_c2" {
  type = object({
    enabled                  = bool
    domain                   = string
    dns_zone_resource_group  = string
    dns_zone_subscription_id = optional(string, "")
    cover_url                = string
    fdid_header_required     = bool
    student_subdomain_format = string
    endpoint_name            = optional(string, "")
    profile_name             = optional(string, "")
  })
  default = {
    enabled                  = false
    domain                   = ""
    dns_zone_resource_group  = ""
    dns_zone_subscription_id = ""
    cover_url                = "https://www.microsoft.com"
    fdid_header_required     = true
    student_subdomain_format = "{sid}"
    endpoint_name            = ""
    profile_name             = ""
  }
}

variable "services" {
  type = object({
    guacamole = object({
      enabled                   = bool
      admin_user                = string
      admin_password            = string
      autoregister              = bool
      student_user_prefix       = optional(string, "student-")
      student_password_template = optional(string, "Student!{n:02d}")
      login_title               = optional(string, "Guidem CWR")
      acme_email                = optional(string, "admin@example.com")
      # Custom DNS hostname plumbing. When dns_zone_name + custom_hostname
      # are both set, terraform writes an A record in Azure DNS and
      # certbot issues the LE cert for `<custom_hostname>.<dns_zone_name>`.
      custom_hostname          = optional(string, "")
      dns_zone_name            = optional(string, "")
      dns_zone_resource_group  = optional(string, "")
      dns_zone_subscription_id = optional(string, "")
    })
    elk = object({
      enabled         = bool
      kibana_user     = string
      kibana_password = string
      deploy_agents   = bool
      public_ip       = optional(bool, true)
    })
    adaptix = object({
      enabled    = bool
      ssh_pubkey = string
      # NOTE: teamserver listens on the uniform :9000 commander port and
      # :8443–:8447 per-CDN HTTPS listener ports. Operator credentials
      # are random per student (see local.effective_adaptix_password).
    })
    redirector = object({
      enabled = bool
      # NOTE: redirector always listens on :443 and selects its upstream
      # port dynamically from which X-Api-* header matched (8443–8447).
    })
    # Ephemeral Kali workspace host (kali-2 docker pool). Mirror of the
    # module-level optional() schema in modules/azure/variables.tf — when
    # absent from tfvars, defaults to {enabled = false}. Must be redeclared
    # here because the root env redefines `variable "services"` and
    # terraform silently drops unknown attributes when a typed object var
    # is set, which is how we lost the workspaces block on the first try.
    workspaces = optional(object({
      enabled              = optional(bool, false)
      pool_size            = optional(number, 4)
      vm_size              = optional(string, "Standard_D4s_v4")
      auto_restart         = optional(bool, true)
      restart_interval_min = optional(number, 30)
    }), {
      enabled              = false
      pool_size            = 4
      vm_size              = "Standard_D4s_v4"
      auto_restart         = true
      restart_interval_min = 30
    })
  })
}

variable "brc4_license_id" {
  type      = string
  default   = ""
  sensitive = true
}
variable "brc4_activation_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "brc4_email" {
  type      = string
  default   = ""
  sensitive = true
}
variable "brc4_blob_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "advanced_c2_validation_wait_minutes" {
  type    = number
  default = 20
}

variable "fast_windows" {
  type    = bool
  default = false
}

variable "baking" {
  type = object({
    enabled             = bool
    resource_group_name = optional(string, "terra-range-images-rg")
    gallery_name        = optional(string, "terra_range_images")
  })
  default = {
    enabled             = false
    resource_group_name = "terra-range-images-rg"
    gallery_name        = "terra_range_images"
  }
}

module "range" {
  source = "../../modules/azure"
  providers = {
    azurerm          = azurerm
    azurerm.dns      = azurerm.dns
    azurerm.guac_dns = azurerm.guac_dns
  }

  range_name                          = var.range_name
  azure_region                        = var.azure_region
  lockdown                            = var.lockdown
  vm_priority                         = var.vm_priority
  guacamole_ingress_cidrs             = var.guacamole_ingress_cidrs
  domain                              = var.domain
  students                            = var.students
  machines                            = var.machines
  student_users                       = var.student_users
  shared_machines                     = var.shared_machines
  advanced_c2                         = var.advanced_c2
  advanced_c2_validation_wait_minutes = var.advanced_c2_validation_wait_minutes
  fast_windows                        = var.fast_windows
  baking                              = var.baking
  services                            = var.services
  brc4_license_id                     = var.brc4_license_id
  brc4_activation_key                 = var.brc4_activation_key
  brc4_email                          = var.brc4_email
  brc4_blob_url                       = var.brc4_blob_url
}

output "guacamole_url" {
  value = module.range.guacamole_url
}

output "guacamole_admin_user" {
  value = module.range.guacamole_admin_user
}

output "guacamole_admin_password" {
  value     = module.range.guacamole_admin_password
  sensitive = true
}

output "elk_kibana_url" {
  value = module.range.elk_kibana_url
}

output "student_logins" {
  value     = module.range.student_logins
  sensitive = true
}

output "machine_ips" {
  value = module.range.machine_ips
}

output "summary" {
  value = module.range.summary
}

output "shared_infra" {
  description = "Public IPs of Ghostwriter / SteppingStones / RedELK."
  value       = module.range.shared_infra
}

output "shared_infra_credentials" {
  value     = module.range.shared_infra_credentials
  sensitive = true
}

output "adaptix_connections" {
  value     = module.range.adaptix_connections
  sensitive = true
}

output "advanced_c2" {
  description = "Front Door endpoint and per-student domains (null when disabled)."
  value       = module.range.advanced_c2
}

output "student_credentials" {
  description = "Per-student random Domain Admin / Adaptix / Mythic passwords. Operator-only."
  value       = module.range.student_credentials
  sensitive   = true
}

# Forwards for outputs that inventory.py + ./range need at root level.
# Child-module outputs aren't visible to `terraform output <name>` (or to
# `terraform show -json`'s root `outputs:` block) unless we re-expose them
# here. inventory.py specifically falls back to a state-walk path when
# `ansible_inventory` is missing — and that fallback doesn't compute AFD
# callback URLs, so mythic_callback_host / adaptix_callbacks come out
# null. Forwarding the rich output fixes that without touching the
# fallback logic.
output "ansible_inventory" {
  description = "Per-VM ansible inventory data (host, ssh user/key, AFD callbacks, per-student creds). Consumed by modules/azure/ansible/inventory.py."
  value       = module.range.ansible_inventory
  sensitive   = true
}

output "guacamole_fqdn" {
  description = "Public FQDN of the Guacamole VM (custom hostname when DNS zone configured, otherwise cloudapp.azure.com)."
  value       = module.range.guacamole_fqdn
}

output "guacamole_acme_email" {
  description = "ACME contact email used by Guacamole's LE issuance."
  value       = module.range.guacamole_acme_email
}

output "operator_ssh_private_key_path" {
  description = "Absolute path to labs/<range_name>/operator-id_ed25519 (read by ./range + inventory.py)."
  value       = module.range.operator_ssh_private_key_path
}

output "operator_ssh_public_key" {
  description = "Operator SSH public key string (authorized on every Linux VM)."
  value       = module.range.operator_ssh_public_key
}

output "lab_dir" {
  description = "Per-deploy artifact directory: labs/<range_name>/."
  value       = module.range.lab_dir
}

output "mythic_connections" {
  description = "Per-student Mythic teamserver connection bundle."
  value       = module.range.mythic_connections
  sensitive   = true
}

output "brc4_connections" {
  description = "Per-student BRC4 teamserver connection bundle."
  value       = module.range.brc4_connections
  sensitive   = true
}

output "sliver_connections" {
  description = "Per-student Sliver teamserver connection bundle."
  value       = module.range.sliver_connections
  sensitive   = true
}

output "cdn_headers" {
  description = "Per-CDN beacon-validation HTTP headers."
  value       = module.range.cdn_headers
  sensitive   = true
}
