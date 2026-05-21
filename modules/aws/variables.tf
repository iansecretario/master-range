################################################################################
# AWS module variables.
#
# Schema mirrors modules/azure/variables.tf so the same generator output
# (envs/<provider>/terraform.tfvars.json) feeds both clouds. Differences:
#
#   - `azure_region` → `region`           (AWS region, e.g. "us-east-1")
#   - `services.guacamole.dns_zone_*`     (Azure DNS) is reused as the
#                                         Route 53 hosted-zone name for the
#                                         Guac LE cert. The "resource group"
#                                         and "subscription" fields are
#                                         ignored on AWS.
#   - `advanced_c2.domain`                drives the CloudFront alias (in
#                                         place of Front Door custom
#                                         domains). For this deployment
#                                         that's `Authrix.com`.
#
# What's intentionally NOT here yet (deferred — TODO):
#   - vm_priority "Spot": EC2 has spot but with a different lifecycle.
#                         We hard-pin to on-demand for the MVP.
#   - workspaces:         the ephemeral kali-2 docker pool. Same userdata
#                         works on EC2 — Tier 2 follow-up.
#   - baking:             AMI baking via Packer. Defer until a workload
#                         actually needs the 25-min savings.
#   - brc4_*:             BRC4 license vars. Plumbed through as no-ops
#                         (an `enabled` BRC4 host is dropped by the
#                         generator when the license is blank, so AWS
#                         simply never sees BRC4 unless licensed).
################################################################################

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

# Honored only for compatibility with the generator's emitted tfvars.
# Spot semantics on AWS differ enough that we pin to on-demand for now;
# operators who need spot can override per-instance later.
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
  validation {
    condition     = var.students.count >= 1 && var.students.count <= 254
    error_message = "students.count must be 1..254."
  }
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
      # Azure-only fields below — accepted for tfvars compatibility, ignored
      # on AWS (Route 53 zones are looked up by name).
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
  description = "Hub-tier infrastructure boxes (Ghostwriter, SteppingStones, RedELK)."
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
  description = "Optional CloudFront fronting per-student c2-redirector. Authrix.com is the default fronting domain for AWS deploys."
  type = object({
    enabled                  = bool
    domain                   = string
    # Azure-only fields kept for tfvars compatibility (ignored on AWS).
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

# Hub CIDR plan mirrors Azure exactly so peering ranges line up if you
# ever want to run a hybrid Azure+AWS lab (TGW + Site-to-Site VPN).
variable "hub_cidr" {
  type    = string
  default = "10.0.0.0/22"
}

variable "hub_mgmt_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "hub_infra_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# BRC4 license vars — plumbed through but unused on AWS (BRC4 host
# would be a Debian EC2 instance with the same userdata; not wired
# in this MVP).
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
