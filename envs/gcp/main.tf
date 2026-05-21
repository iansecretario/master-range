terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
  # Optional remote state — uncomment and configure for team use:
  # backend "gcs" {
  #   bucket = "terra-range-tfstate"
  #   prefix = "envs/gcp"
  # }
}

# ============================================================================
# One-project-per-range architecture.
# ============================================================================
# Every `./range apply` provisions resources into its OWN GCP project. This
# is the inverse of Azure's "one subscription, multiple resource groups"
# pattern — we lean into GCP-native isolation because:
#
#   1. Project deletion is atomic. `terraform destroy` (which calls
#      google_project.range's destroy) cascades to every VPC, VM, secret,
#      disk, firewall rule, NAT, etc. inside the project. Vs. Azure where
#      we had to manually un-pin lifecycle prevent_destroy + state-rm
#      orphaned RGs.
#   2. Per-range quota isolation. Each project gets its own vCPU + PIP +
#      VNet quotas. Cohort builds across N students don't share one
#      bucket of compute quota.
#   3. Billing reports trivial. `gcloud billing` groups by project, so
#      cost-per-range is one query.
#   4. Cross-range network isolation by default. No VPC peering means
#      no accidental cross-student traffic.
#
# Two project IDs in play:
#
#   var.gcp_project_id      → the PER-RANGE project (created here, ephemeral).
#                              Empty string in tfvars means terraform
#                              creates one named "${range_name}-${rand}".
#                              Non-empty means operator pre-created it via
#                              `gcloud projects create`.
#   var.gcp_host_project_id → the SHARED host project (long-lived, operator-
#                              managed). Holds the baked-image registry +
#                              Cloud DNS zones. NEVER created/destroyed by
#                              terra-range.
#
# Project creation requires:
#   - var.gcp_billing_account (org-level billing account that pays the bill)
#   - var.gcp_parent_folder_id OR var.gcp_parent_org_id (folder/org to nest under)
#   - operator's gcloud identity has roles/resourcemanager.projectCreator
#     at the folder/org level.
#
# If the operator doesn't have project-creator IAM, set var.gcp_project_id
# to a pre-existing project ID and var.gcp_create_project = false (the
# google_project + google_project_service resources will skip via count=0).
# ============================================================================

locals {
  # GCP project IDs MUST be 6-30 chars, lowercase, start with a letter,
  # only [a-z0-9-], and end alphanumeric. Sanitize range_name aggressively.
  sanitized_range_name = lower(substr(replace(replace(var.range_name, "_", "-"), "/[^a-z0-9-]/", ""), 0, 20))

  # DETERMINISTIC per-range project ID. Derived from sha256(range_name)
  # rather than a random_id resource because:
  #   1. random_id is `(known after apply)` on first plan, which makes
  #      every downstream resource's plan collapse to "known after apply"
  #      — `terraform plan` shows 1 resource instead of the full 57.
  #   2. Deterministic IDs mean re-applies of the same scenario hit the
  #      same project (idempotent), and `./range destroy` followed by
  #      `./range apply` doesn't churn project IDs.
  #   3. sha256 of range_name is collision-resistant within a 6-char
  #      hex suffix at terra-range's scale (≪ 16M distinct ranges).
  #
  # If a different deterministic seed is needed (e.g., per-environment
  # variants of the same scenario), set var.gcp_project_id explicitly.
  project_id_suffix = substr(sha256(var.range_name), 0, 6)

  # Final project_id: caller-supplied if var.gcp_project_id != "", else
  # auto-generated as "<sanitized-range-name>-<hash>".
  effective_project_id = (
    var.gcp_project_id != ""
    ? var.gcp_project_id
    : "${local.sanitized_range_name}-${local.project_id_suffix}"
  )
}

# The per-range project itself. Skipped (count=0) when the operator
# pre-created the project and just wants terraform to USE it.
resource "google_project" "range" {
  count           = var.gcp_create_project ? 1 : 0
  name            = "terra-range: ${var.range_name}"
  project_id      = local.effective_project_id
  billing_account = var.gcp_billing_account

  # Exactly one of folder_id / org_id MUST be set (GCP enforces this).
  # We prefer folder_id since orgs typically have a per-team folder
  # structure; org_id is the fallback.
  folder_id = var.gcp_parent_folder_id != "" ? var.gcp_parent_folder_id : null
  org_id    = var.gcp_parent_folder_id == "" && var.gcp_parent_org_id != "" ? var.gcp_parent_org_id : null

  labels = {
    range   = lower(replace(var.range_name, "_", "-"))
    product = "terra-range"
    managed = "terraform"
  }

  # Don't auto-create the default network at project create time — we
  # build our own VPC in modules/gcp/network.tf.
  auto_create_network = false

  # Don't delete the default service account on destroy (it has billing
  # implications across the org). deletion_policy = "DELETE" would force
  # the project into the 30-day soft-delete pool on `terraform destroy`.
  deletion_policy = "DELETE"
}

# API enablement — every Google Cloud API that terra-range touches must
# be enabled in the per-range project. Done via google_project_service
# resources (one per API). Each takes ~30s to enable; we enable ~8 so
# expect ~4 min of "Enabling services" output on first apply.
#
# disable_on_destroy = false — when the project is deleted, the service
# is gone anyway; explicit disable wastes API time.
locals {
  required_services = [
    "compute.googleapis.com",        # google_compute_*
    "dns.googleapis.com",            # google_dns_*
    "iam.googleapis.com",            # service accounts
    "iamcredentials.googleapis.com", # OAuth-flow IAM
    "secretmanager.googleapis.com",  # google_secret_manager_*
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",  # private-services-access (Cloud SQL etc.)
    "storage.googleapis.com",            # GCS for packer logs + state
    "certificatemanager.googleapis.com", # managed certs for LB (Phase D)
  ]
}

resource "google_project_service" "apis" {
  for_each = var.gcp_create_project ? toset(local.required_services) : toset([])

  project            = google_project.range[0].project_id
  service            = each.value
  disable_on_destroy = false

  # Wait for the project to be fully provisioned before enabling services.
  depends_on = [google_project.range]
}

provider "google" {
  project = local.effective_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = local.effective_project_id
  region  = var.gcp_region
}

# Aliased provider for the Cloud DNS managed zone hosting the registered
# C2 domain. DNS zones live in the LONG-LIVED host project (not the
# per-range ephemeral project), so by default this provider targets
# var.gcp_host_project_id. Operator can override per-scenario with
# advanced_c2.dns_zone_subscription_id (re-mapped from the Azure-side
# field name for cross-provider symmetry).
provider "google" {
  alias = "dns"
  project = (
    var.advanced_c2.dns_zone_subscription_id != ""
    ? var.advanced_c2.dns_zone_subscription_id
    : (var.gcp_host_project_id != "" ? var.gcp_host_project_id : local.effective_project_id)
  )
  region = var.gcp_region
}

provider "google-beta" {
  alias = "dns"
  project = (
    var.advanced_c2.dns_zone_subscription_id != ""
    ? var.advanced_c2.dns_zone_subscription_id
    : (var.gcp_host_project_id != "" ? var.gcp_host_project_id : local.effective_project_id)
  )
  region = var.gcp_region
}

# Aliased provider for the operator-facing Guacamole custom hostname.
# Same idea as `google.dns` but scoped to the Guacamole DNS zone (often
# a different domain + a different project).
provider "google" {
  alias = "guac_dns"
  project = (
    try(var.services.guacamole.dns_zone_subscription_id, "") != ""
    ? var.services.guacamole.dns_zone_subscription_id
    : (var.gcp_host_project_id != "" ? var.gcp_host_project_id : local.effective_project_id)
  )
  region = var.gcp_region
}

provider "google-beta" {
  alias = "guac_dns"
  project = (
    try(var.services.guacamole.dns_zone_subscription_id, "") != ""
    ? var.services.guacamole.dns_zone_subscription_id
    : (var.gcp_host_project_id != "" ? var.gcp_host_project_id : local.effective_project_id)
  )
  region = var.gcp_region
}

# ---- pass-through variables (filled by terraform.tfvars.json) ----
variable "range_name" {
  type = string
}

# GCP-specific: per-range project ID. There's no Azure equivalent
# (subscription_id lives on the provider block). All resources in the
# module are scoped to this project.
#
# Set to empty string ("") to have terraform auto-generate a unique
# project ID per range deploy (recommended; works with var.gcp_create_project=true).
# Set to a pre-existing project ID to have terraform USE that project
# (requires var.gcp_create_project=false).
variable "gcp_project_id" {
  type        = string
  default     = ""
  description = "Per-range GCP project ID. Empty = auto-generate from range_name + random suffix."
}

# Whether terraform creates the per-range project itself, or uses one
# the operator pre-created via `gcloud projects create`. Default true:
# one-project-per-range with terraform-managed lifecycle.
variable "gcp_create_project" {
  type        = bool
  default     = true
  description = "Have terraform create + own the per-range project (true) or use a pre-existing project (false). Requires resourcemanager.projectCreator IAM at folder/org level when true."
}

# Billing account that pays for the per-range project. REQUIRED when
# gcp_create_project=true. Operator gets the ID from
# `gcloud beta billing accounts list`.
variable "gcp_billing_account" {
  type        = string
  default     = ""
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX format) that pays for the per-range project. Required when gcp_create_project=true."
}

# Where the per-range project sits in the resource hierarchy. EXACTLY
# ONE of folder_id / org_id should be set. Folder is preferred for
# per-team scoping; org is the fallback for flat-hierarchy orgs.
variable "gcp_parent_folder_id" {
  type        = string
  default     = ""
  description = "GCP folder ID (numeric) to nest the per-range project under. Empty = use gcp_parent_org_id instead."
}

variable "gcp_parent_org_id" {
  type        = string
  default     = ""
  description = "GCP organization ID (numeric) to nest the per-range project under. Used only when gcp_parent_folder_id is empty."
}

# SHARED host project — holds baked images + Cloud DNS zones + any
# other org-level long-lived resources. NEVER created/destroyed by
# terra-range; operator manages it via gcloud manually.
#
# Empty = baked images live in the per-range project (single-deploy
# testing only; baked images get destroyed with the range).
variable "gcp_host_project_id" {
  type        = string
  default     = ""
  description = "Long-lived shared GCP project holding the baked-image registry + DNS zones. Empty = use per-range project (testing only)."
}

# The module currently uses `azure_region` as the cross-provider region
# variable for backward compat with the generator. We expose `gcp_region`
# at the env layer for clarity AND pass it through to the module's
# `azure_region` arg. Either name in tfvars works — `gcp_region` wins if
# set; `azure_region` is the legacy fallback.
variable "gcp_region" {
  type    = string
  default = "asia-southeast1" # Singapore — equivalent of southeastasia
}

variable "azure_region" {
  type        = string
  default     = "asia-southeast1"
  description = "Legacy variable name kept for tfvars compatibility. Use gcp_region in new scenarios."
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
    per_student        = optional(bool, true)
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
      vm_size              = optional(string, "n2-standard-4")
      auto_restart         = optional(bool, true)
      restart_interval_min = optional(number, 30)
      }), {
      enabled              = false
      pool_size            = 4
      vm_size              = "n2-standard-4"
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
    enabled                     = bool
    resource_group_name         = optional(string, "terra-range-images-rg")
    gallery_name                = optional(string, "terra_range_images")
    use_baked_kali              = optional(bool, false)
    use_baked_win_server_2025   = optional(bool, false)
    use_baked_win_server_2022   = optional(bool, false)
    use_baked_win_server_2019   = optional(bool, false)
    use_baked_win_10            = optional(bool, false)
    use_baked_win_11            = optional(bool, false)
    use_baked_elk               = optional(bool, false)
    use_baked_redelk            = optional(bool, false)
    use_baked_debian_redirector = optional(bool, false)
    use_baked_guacamole         = optional(bool, false)
    use_baked_adaptix           = optional(bool, false)
    use_baked_mythic            = optional(bool, false)
    use_baked_sliver            = optional(bool, false)
    use_baked_ghostwriter       = optional(bool, false)
    use_baked_stepping_stones   = optional(bool, false)
  })
  default = {
    enabled             = false
    resource_group_name = "terra-range-images-rg"
    gallery_name        = "terra_range_images"
  }
}

module "range" {
  source = "../../modules/gcp"
  providers = {
    google               = google
    google.dns           = google.dns
    google.guac_dns      = google.guac_dns
    google-beta          = google-beta
    google-beta.dns      = google-beta.dns
    google-beta.guac_dns = google-beta.guac_dns
  }

  range_name          = var.range_name
  gcp_project_id      = local.effective_project_id
  gcp_host_project_id = var.gcp_host_project_id
  azure_region        = var.gcp_region

  # When terraform creates the project, the module's resources must
  # wait until the API enablement completes — otherwise the first
  # google_compute_* call hits "compute.googleapis.com has not been
  # used in project ..." while the API is still enabling.
  depends_on = [
    google_project.range,
    google_project_service.apis,
  ]
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

# Outputs — mirror envs/azure/main.tf exactly. inventory.py + ./range read these.

output "guacamole_url" { value = module.range.guacamole_url }
output "guacamole_admin_user" { value = module.range.guacamole_admin_user }
output "guacamole_admin_password" {
  value     = module.range.guacamole_admin_password
  sensitive = true
}
output "elk_kibana_url" { value = module.range.elk_kibana_url }
output "student_logins" {
  value     = module.range.student_logins
  sensitive = true
}
output "machine_ips" { value = module.range.machine_ips }
output "summary" { value = module.range.summary }
output "shared_infra" { value = module.range.shared_infra }
output "shared_infra_credentials" {
  value     = module.range.shared_infra_credentials
  sensitive = true
}
output "adaptix_connections" {
  value     = module.range.adaptix_connections
  sensitive = true
}
output "advanced_c2" { value = module.range.advanced_c2 }
output "student_credentials" {
  value     = module.range.student_credentials
  sensitive = true
}
output "ansible_inventory" {
  value     = module.range.ansible_inventory
  sensitive = true
}
output "guacamole_fqdn" { value = module.range.guacamole_fqdn }
output "guacamole_acme_email" { value = module.range.guacamole_acme_email }
output "operator_ssh_private_key_path" { value = module.range.operator_ssh_private_key_path }
output "operator_ssh_public_key" { value = module.range.operator_ssh_public_key }
output "lab_dir" { value = module.range.lab_dir }
output "mythic_connections" {
  value     = module.range.mythic_connections
  sensitive = true
}
output "brc4_connections" {
  value     = module.range.brc4_connections
  sensitive = true
}
output "sliver_connections" {
  value     = module.range.sliver_connections
  sensitive = true
}
output "cdn_headers" {
  value     = module.range.cdn_headers
  sensitive = true
}

# One-project-per-range bookkeeping: surface the auto-generated project
# ID so the operator (and the ./range CLI) can introspect it. When
# var.gcp_create_project=true this is also the project terraform
# manages; when false it's the pre-existing project terraform uses.
output "gcp_project_id" {
  description = "GCP project ID this range deploys into (auto-generated from range_name when var.gcp_project_id is empty)."
  value       = local.effective_project_id
}

output "gcp_host_project_id" {
  description = "Shared host project holding baked images + DNS zones (empty = single-project mode)."
  value       = var.gcp_host_project_id
}

output "gcp_region" {
  value = var.gcp_region
}
