################################################################################
# Module entrypoint — top-level locals + project metadata for the GCP provider.
#
# Invocation contract (mirrored from modules/azure/main.tf):
#   module "range" {
#     source     = "../../modules/gcp"
#     range_name = "redteam-lab"
#
#     gcp_project_id = "cwr-redteam-prod"      # owns every resource in this module
#     azure_region   = "asia-southeast1"       # named for parity with Azure side
#     vm_priority    = "Regular"               # or "Spot" for cost-optimised labs
#
#     domain   = var.domain
#     students = var.students
#     machines = var.machines
#     services = var.services
#     shared_machines = var.shared_machines
#     advanced_c2     = var.advanced_c2
#
#     providers = {
#       google           = google                 # primary deploy project
#       google.dns       = google.dns             # registered C2 domain (cdn.tf)
#       google.guac_dns  = google.guac_dns        # operator-facing guac hostname
#       google-beta      = google-beta
#       google-beta.dns       = google-beta.dns
#       google-beta.guac_dns  = google-beta.guac_dns
#     }
#   }
#
# What this file owns
# -------------------
# 1. Top-level locals that don't fit cleanly into one of the per-feature .tf
#    files: deploy timestamp, common labels, the resolved zone, range prefix.
# 2. A read-only data lookup of the project we're deploying into — used by
#    services.tf for the project_number (some IAP / Cloud Build resources
#    require the numeric form).
# 3. NOTHING else. Network is in network.tf, firewall is in firewall.tf,
#    VMs are in vms.tf, shared infra is in shared_infra.tf, etc.
#
# What this file deliberately does NOT own
# ----------------------------------------
#   - `local.students`           → defined in network.tf (single source)
#   - `local.effective_*_password` → defined in passwords.tf
#   - `local.cdn_headers`        → defined in passwords.tf
#   - `local.shared_source_image_id` → defined in images.tf (parallel agent)
#   - `local.is_windows`         → defined in images.tf (parallel agent)
#   - `local.guac_effective_fqdn` → defined in guacamole_dns.tf (parallel)
################################################################################

# NOTE: A previous version had `data "google_project" "current"` here to
# expose the numeric project_number. Removed because:
#   1. Nothing in the module actually consumed it.
#   2. With var.gcp_create_project=true (the one-project-per-range
#      default), the project DOESN'T EXIST yet at terraform plan/refresh
#      time — the data source would fail with `404 Project not found`
#      and block the first apply. Adding `depends_on = [google_project.range]`
#      doesn't help because data sources are refreshed in the
#      data-source phase, not interleaved with resource creation.
#   3. If a future feature genuinely needs the numeric project number,
#      use `${google_project.range[0].number}` (from envs/gcp/main.tf)
#      passed in via a new module input variable.

# Resolve a default zone from the configured region. Used by per-VM resources
# that need a zone (compute instances are zonal even though subnets are
# regional). vms.tf and shared_infra.tf reference local.gcp_zone; if a future
# agent wants per-VM zone pinning for HA spreading, override this map.
locals {
  # Hard-coded "<region>-b" fallback. Every GCE region exposes a b-zone, so
  # this works as a sane default. Scenarios needing zone-spread should set
  # per-VM zone metadata via a future `var.gcp_zone` override.
  gcp_zone = "${var.azure_region}-b"

  # Common labels applied to every resource in the module. GCP labels are
  # lowercased and constrained to [a-z0-9_-] — see the per-resource doc.
  # `terra-range` is the consistent product label across providers; consumers
  # can grep all resources for this label to enumerate every range deploy.
  common_labels = {
    range   = lower(replace(var.range_name, "_", "-"))
    product = "terra-range"
    managed = "terraform"
  }

  # ISO 8601 deploy timestamp baked into VM descriptions + a creation-stamp
  # label. Useful for cost reporting (label-grouped billing) and for the
  # `./range list` UI which sorts by deploy time. Recomputed on every apply,
  # but every resource that consumes it has `ignore_changes = [labels]` (or
  # `description`) so existing infra doesn't churn on re-apply.
  deploy_timestamp = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timestamp())

  # Short range prefix used by every resource name. Sanitised to GCP's
  # [a-z]([-a-z0-9]*[a-z0-9])? rule — uppercase + underscore would be
  # rejected by google_compute_* validators. Matches the convention in
  # network.tf / firewall.tf which already use `var.range_name` directly
  # (so scenario YAML must keep range_name lower-case-with-hyphens).
  range_prefix = lower(replace(var.range_name, "_", "-"))

  # ----- Per-machine IP merge map ----------------------------------------
  # GCP has ONE compute resource type for both OS families, but vms.tf
  # splits them across two `google_compute_instance` resources keyed by
  # the same m.name (one filtered to Linux roles, one to Windows). Other
  # files (outputs.tf, services.tf) need to reach an IP by m.name without
  # caring which family the VM is. Merge into a single map here.
  #
  # Azure has a single `azurerm_*_virtual_machine.machine` collection so
  # the merge isn't needed; this is the GCP-specific delta.
  machine_private_ip = merge(
    { for k, v in google_compute_instance.linux :
    k => v.network_interface[0].network_ip },
    { for k, v in google_compute_instance.windows :
    k => v.network_interface[0].network_ip },
  )

  # Same shape but for the optional external IP. Most VMs don't get a
  # PIP (only c2-redirectors + the guacamole hub do); for the rest this
  # returns null and consumers default-coalesce.
  machine_public_ip = merge(
    {
      for k, v in google_compute_instance.linux :
      k => try(v.network_interface[0].access_config[0].nat_ip, null)
    },
    {
      for k, v in google_compute_instance.windows :
      k => try(v.network_interface[0].access_config[0].nat_ip, null)
    },
  )

  # The Azure side has `azurerm_*_virtual_machine.machine[name].name`;
  # GCP needs the same string for templating. Reconstruct it from the
  # range prefix + machine name (matches the convention `vms.tf` uses
  # to set `google_compute_instance.<linux|windows>[k].name`).
  machine_hostname = {
    for m in var.machines :
    m.name => "${local.range_prefix}-${m.name}"
  }
}
