################################################################################
# AWS environment layer.
#
# Wraps modules/aws/ exactly like envs/azure/main.tf wraps modules/azure/.
# Variables here mirror what the generator emits in terraform.tfvars.json
# (same generator, provider-agnostic schema).
#
# Pre-flight requirements:
#   - aws CLI installed + `aws configure` / `aws sso login`
#   - AWS Marketplace subscription accepted ONCE for Offensive Security's
#     Kali AMI (https://aws.amazon.com/marketplace/pp/prodview-fznsw3f7mq7to)
#   - If using advanced_c2: a public Route 53 hosted zone for the domain
#     (Authrix.com for this project). Delegation can stay at your
#     registrar; the zone just needs to exist in this AWS account.
################################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Range     = var.range_name
      ManagedBy = "terra-range"
    }
  }
}

# CloudFront's ACM certs MUST live in us-east-1, regardless of the rest
# of the stack. Module references this via `provider = aws.us_east_1`.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Range     = var.range_name
      ManagedBy = "terra-range"
    }
  }
}

module "range" {
  source = "../../modules/aws"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  range_name              = var.range_name
  region                  = var.region
  lockdown                = var.lockdown
  vm_priority             = var.vm_priority
  guacamole_ingress_cidrs = var.guacamole_ingress_cidrs
  domain                  = var.domain
  students                = var.students
  machines                = var.machines
  student_users           = var.student_users
  shared_machines         = var.shared_machines
  services                = var.services
  advanced_c2             = var.advanced_c2
  advanced_c2_validation_wait_minutes = var.advanced_c2_validation_wait_minutes
  fast_windows            = var.fast_windows
  baking                  = var.baking
  brc4_license_id         = var.brc4_license_id
  brc4_activation_key     = var.brc4_activation_key
  brc4_email              = var.brc4_email
}

# ============================================================================
# Variable mirrors. Same shape as envs/azure/main.tf so the generator's
# emitted tfvars work unchanged.
# ============================================================================
variable "range_name" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "lockdown" {
  type    = bool
  default = false
}

variable "vm_priority" {
  type    = string
  default = "Regular"
}

variable "guacamole_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
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
      custom_hostname           = optional(string, "")
      dns_zone_name             = optional(string, "")
      dns_zone_resource_group   = optional(string, "")
      dns_zone_subscription_id  = optional(string, "")
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
    })
    redirector = object({
      enabled = bool
    })
    workspaces = optional(object({
      enabled              = optional(bool, false)
      pool_size            = optional(number, 4)
      vm_size              = optional(string, "t3.xlarge")
      auto_restart         = optional(bool, true)
      restart_interval_min = optional(number, 30)
    }), {
      enabled              = false
      pool_size            = 4
      vm_size              = "t3.xlarge"
      auto_restart         = true
      restart_interval_min = 30
    })
  })
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
    dns_zone_resource_group  = optional(string, "")
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

# ============================================================================
# Outputs — re-export from the module.
# ============================================================================
output "guacamole_url"               { value = module.range.guacamole_url }
output "guacamole_fqdn"              { value = module.range.guacamole_fqdn }
output "guacamole_acme_email"        { value = module.range.guacamole_acme_email }
output "guacamole_admin_user"        { value = module.range.guacamole_admin_user }
output "guacamole_admin_password" {
  value     = module.range.guacamole_admin_password
  sensitive = true
}
output "elk_kibana_url"              { value = module.range.elk_kibana_url }
output "operator_ssh_private_key_path" { value = module.range.operator_ssh_private_key_path }
output "lab_dir"                     { value = module.range.lab_dir }
output "machine_ips"                 { value = module.range.machine_ips }
output "advanced_c2"                 { value = module.range.advanced_c2 }
output "student_users"               { value = module.range.student_users }
output "range_name"                  { value = module.range.range_name }
output "summary"                     { value = module.range.summary }
