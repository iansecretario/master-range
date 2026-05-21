################################################################################
# envs/shared-guac-gcp — persistent shared Guacamole deployment on GCP.
#
# GCP port of envs/shared-guac-azure. This env dir has its OWN terraform
# state, independent of any envs/azure/, envs/aws/, envs/gcp/, or
# envs/inst-NN-* per-range deploy. The shared Guac it stands up serves
# every range that registers connections into it.
#
# Lifecycle:
#   terraform apply   ─►  create / converge the shared Guac
#   terraform apply   ─►  no-op on subsequent runs (idempotent)
#   terraform destroy ─►  tear down the shared Guac entirely
#                         (only do this when migrating away — every
#                          deployed range will lose its UI access until
#                          a new shared Guac is brought up + range
#                          applies re-register)
#
# Don't ever `state rm` this — it's the source of truth for the Guac
# the rest of terra-range's range applies call into.
#
# ── Why a standalone config, not a modules/shared-guac/ port? ─────────
# modules/shared-guac/ is Azure-specific (azurerm_resource_group, NSG,
# azurerm_dns_a_record). Rather than forking it into
# modules/shared-guac-gcp/, this env dir IS the deployment — provisions
# its own project + VPC + NAT + firewall + Guac VM directly.
#
# Reuses heavily from the per-range GCP module:
#   - modules/azure/userdata/guacamole.sh  (provider-agnostic cloud-init)
#   - same Guacamole admin/register.py pattern (empty manifest on first
#     boot; range applies POST connections via the REST API in Phase 2B)
################################################################################

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Optional remote state — uncomment and configure for team use. The
  # shared-Guac state is the ONE state file every other range deploy
  # cares about; backing it in GCS makes it shareable.
  # backend "gcs" {
  #   bucket = "terra-range-tfstate"
  #   prefix = "envs/shared-guac-gcp"
  # }
}

################################################################################
# Locals
################################################################################

locals {
  # GCP project IDs: 6-30 chars, lowercase, start with a letter,
  # [a-z0-9-], end alphanumeric. Sanitize cohort_name aggressively.
  sanitized_cohort = lower(substr(replace(replace(var.cohort_name, "_", "-"), "/[^a-z0-9-]/", ""), 0, 20))

  # Deterministic per-cohort project ID (same approach as envs/gcp/main.tf —
  # see that file for the rationale around sha256 vs random_id).
  project_id_suffix = substr(sha256(var.cohort_name), 0, 6)

  effective_project_id = (
    var.gcp_project_id != ""
    ? var.gcp_project_id
    : "${local.sanitized_cohort}-${local.project_id_suffix}"
  )

  # Effective admin password — random when caller leaves it blank.
  effective_admin_password = (
    var.guacamole_admin_password != ""
    ? var.guacamole_admin_password
    : random_password.admin.result
  )

  # Custom DNS active when both zone + hostname are set. We also need a
  # project to look the zone up in: caller-supplied dns_zone_project_id,
  # falling back to the shared-Guac project itself (rare; usually the
  # zone lives in a separate long-lived host project).
  use_custom_dns = (
    var.dns_zone_name != "" && var.custom_hostname != ""
  )

  effective_dns_zone_project = (
    var.dns_zone_project_id != ""
    ? var.dns_zone_project_id
    : local.effective_project_id
  )

  # FQDN the operator types into a browser. When no custom DNS, this is
  # null — outputs surface the bare public IP instead.
  effective_fqdn = (
    local.use_custom_dns
    ? "${var.custom_hostname}.${var.dns_zone_name}"
    : null
  )

  common_labels = {
    cohort  = lower(replace(var.cohort_name, "_", "-"))
    product = "terra-range"
    role    = "shared-guac"
    managed = "terraform"
  }

  # GCP firewall rules cap at 256 source ranges per rule. Chunk at 250
  # for safety. Same approach as modules/gcp/firewall.tf.
  _fw_cidr_chunk_size = 250

  # Google IAP TCP forwarder range. Documented at
  # https://cloud.google.com/iap/docs/using-tcp-forwarding
  iap_source_range = "35.235.240.0/20"

  # API enablement list. Bare minimum for the shared Guac:
  #   - compute (VPC, NAT, firewall, VM)
  #   - dns (custom-hostname A record; harmless when unused)
  #   - iam + iamcredentials (default SA on the Guac VM)
  #   - cloudresourcemanager (project metadata reads at refresh time)
  required_services = [
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

################################################################################
# Random admin password (28-char). Used when var.guacamole_admin_password is
# left blank (recommended).
################################################################################

resource "random_password" "admin" {
  length      = 28
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 1
  # JSON-safe + shell-safe — no backslash, single-quote, or double-quote.
  override_special = "!@#%^&*-_+="
}

################################################################################
# Project (created when var.gcp_create_project=true). Same pattern as
# envs/gcp/main.tf — see that file for the full one-project-per-deploy
# rationale.
################################################################################

resource "google_project" "shared_guac" {
  count = var.gcp_create_project ? 1 : 0

  name            = "terra-range shared-Guac: ${var.cohort_name}"
  project_id      = local.effective_project_id
  billing_account = var.gcp_billing_account

  folder_id = var.gcp_parent_folder_id != "" ? var.gcp_parent_folder_id : null
  org_id    = var.gcp_parent_folder_id == "" && var.gcp_parent_org_id != "" ? var.gcp_parent_org_id : null

  labels = {
    cohort  = lower(replace(var.cohort_name, "_", "-"))
    product = "terra-range"
    role    = "shared-guac"
    managed = "terraform"
  }

  auto_create_network = false
  deletion_policy     = "DELETE"
}

resource "google_project_service" "apis" {
  for_each = var.gcp_create_project ? toset(local.required_services) : toset([])

  project            = google_project.shared_guac[0].project_id
  service            = each.value
  disable_on_destroy = false

  depends_on = [google_project.shared_guac]
}

################################################################################
# Provider blocks. Default points at the shared-Guac project; aliased
# `dns` points at the zone-owning project (typically a long-lived host
# project distinct from this deployment).
################################################################################

provider "google" {
  project = local.effective_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = local.effective_project_id
  region  = var.gcp_region
}

provider "google" {
  alias   = "dns"
  project = local.effective_dns_zone_project
  region  = var.gcp_region
}

################################################################################
# Network — one VPC, one subnet, one Cloud NAT, three firewall rules.
# Smaller than the per-range hub since there's only one VM (the Guac
# itself) and no per-student spokes.
################################################################################

resource "google_compute_network" "guac" {
  name                    = "${var.cohort_name}-vpc"
  project                 = local.effective_project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = 1460

  description = "${var.cohort_name} shared Guac VPC."

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "guac" {
  name                     = "${var.cohort_name}-subnet"
  project                  = local.effective_project_id
  region                   = var.gcp_region
  network                  = google_compute_network.guac.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Cloud Router + NAT for egress. The Guac VM does have a public IP, but
# we run NAT anyway so any future intra-VPC sidecar (e.g. a hosted
# register.py worker) can reach package mirrors without its own PIP.
resource "google_compute_router" "nat" {
  name        = "${var.cohort_name}-nat-router"
  project     = local.effective_project_id
  region      = var.gcp_region
  network     = google_compute_network.guac.id
  description = "Cloud NAT control-plane router for ${var.cohort_name}. No BGP — NAT use only."
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cohort_name}-nat"
  project                            = local.effective_project_id
  region                             = var.gcp_region
  router                             = google_compute_router.nat.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  min_ports_per_vm                   = 64

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

################################################################################
# Firewall rules.
#   1. allow-https — :443 from guacamole_ingress_cidrs (chunked at 250).
#   2. allow-acme-http — :80 from 0.0.0.0/0 for Let's Encrypt HTTP-01.
#   3. allow-iap-ssh — IAP TCP-forwarder range for SSH troubleshooting.
################################################################################

resource "google_compute_firewall" "allow_https" {
  for_each = {
    for idx, chunk in chunklist(var.guacamole_ingress_cidrs, local._fw_cidr_chunk_size) :
    tostring(idx) => chunk
  }

  name    = "${var.cohort_name}-allow-https-${each.key}"
  project = local.effective_project_id
  network = google_compute_network.guac.name

  description = "Operator + student ingress to shared Guac on :443 (chunk ${each.key})."
  direction   = "INGRESS"
  priority    = 1000 + tonumber(each.key)

  source_ranges = each.value
  target_tags   = ["guacamole"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "allow_acme_http" {
  name    = "${var.cohort_name}-allow-acme-http"
  project = local.effective_project_id
  network = google_compute_network.guac.name

  description = "Let's Encrypt HTTP-01 challenge on :80 (world-readable; nginx redirects to HTTPS for everything else)."
  direction   = "INGRESS"
  priority    = 1500

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["guacamole"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.cohort_name}-allow-iap-ssh"
  project = local.effective_project_id
  network = google_compute_network.guac.name

  description = "Operator SSH via IAP TCP forwarder (gcloud compute start-iap-tunnel)."
  direction   = "INGRESS"
  priority    = 900

  source_ranges = [local.iap_source_range]
  target_tags   = ["guacamole"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

################################################################################
# Static public IP + DNS A record.
#
# Cloud DNS path is OPTIONAL — only fires when dns_zone_name +
# custom_hostname are both set. When unset, the Guac is reachable only
# by raw public IP and cloud-init falls back to a self-signed cert.
################################################################################

resource "google_compute_address" "guac" {
  name         = "${var.cohort_name}-guac-pip"
  project      = local.effective_project_id
  region       = var.gcp_region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  description  = "Static public IP for shared Guacamole VM (cohort ${var.cohort_name})."
}

data "google_dns_managed_zone" "guac" {
  provider = google.dns
  count    = local.use_custom_dns ? 1 : 0
  name     = var.dns_zone_name
  project  = local.effective_dns_zone_project
}

resource "google_dns_record_set" "guac" {
  provider     = google.dns
  count        = local.use_custom_dns ? 1 : 0
  managed_zone = data.google_dns_managed_zone.guac[0].name
  # rrset names are fully qualified with trailing dot.
  name    = "${var.custom_hostname}.${var.dns_zone_name}."
  type    = "A"
  ttl     = 300
  rrdatas = [google_compute_address.guac.address]
  project = data.google_dns_managed_zone.guac[0].project
}

################################################################################
# Guacamole VM. Re-uses modules/azure/userdata/guacamole.sh — the
# cloud-init is provider-agnostic, picks up the FQDN at render time, and
# runs certbot via HTTP-01 against whatever value we pass for guac_fqdn.
#
# Sizing rationale:
#   e2-standard-4 (4 vCPU / 16 GB). Idle steady-state ~1 GB; per-session
#   RAM is dominated by guacd ferrying RDP/VNC frames (~30 MB/active).
#   Comfortably handles 30-50 concurrent operator+student sessions.
#
# NEVER use Spot for the shared Guac. Eviction would drop EVERY
# operator + student session simultaneously and require a manual restart
# + cache warmup. Pay PAYG; the savings on Spot don't outweigh the user
# disruption.
################################################################################

resource "google_compute_instance" "guac" {
  name         = "${var.cohort_name}-guac"
  project      = local.effective_project_id
  zone         = "${var.gcp_region}-b"
  machine_type = var.vm_size

  description = "Shared Guacamole VM for cohort ${var.cohort_name}."

  # Regular (not Spot) — see header comment.
  scheduling {
    provisioning_model  = "STANDARD"
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  boot_disk {
    auto_delete = true
    device_name = "${var.cohort_name}-guac-osdisk"
    initialize_params {
      # 128 GB — Postgres growth + Docker image cache + LE cert + log
      # rotation over the long-lived deployment lifetime. Double the
      # per-range Guac's 60 GB since this one holds N cohorts' worth of
      # connection records.
      size  = 128
      type  = "pd-balanced"
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.guac.name
    network_ip = var.static_ip

    access_config {
      nat_ip       = google_compute_address.guac.address
      network_tier = "PREMIUM"
    }
  }

  # Default Compute Engine SA with cloud-platform scope. Lets cloud-init
  # do certbot-dns-google if a future operator opts into wildcard certs
  # via the DNS-01 path (not used in the Phase MVP — HTTP-01 is the
  # cert path).
  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  metadata = {
    ssh-keys           = var.operator_ssh_pubkey != "" ? "guacadmin:${var.operator_ssh_pubkey}" : ""
    enable-oslogin     = "FALSE"
    serial-port-enable = "FALSE"

    # Reuse the per-range Guac userdata. The script is idempotent on
    # first boot: writes the empty manifest, starts the docker-compose
    # stack (postgres + guacd + guacamole + nginx), runs register.py
    # which finds no connections and exits cleanly. Range applies later
    # POST to /api/... to register their connections (Phase 2B).
    #
    # Variables that come from the per-range userdata's wildcard-cert
    # path (KV name, wildcard zone) are set empty here — the userdata's
    # bootstrap script detects empty values and falls back to the
    # simpler HTTP-01 path. That's exactly what we want for the shared
    # Guac MVP: HTTP-01 cert for guac.<zone>, admin_password for
    # SSH access if needed.
    #
    # If local.effective_fqdn is null (no custom DNS), feed the public
    # IP — certbot will then SKIP cert issuance (LE can't validate an
    # IP) and the userdata's self-signed fallback takes over.
    user-data = templatefile("${path.module}/../../modules/azure/userdata/guacamole.sh", {
      admin_user     = var.guacamole_admin_user
      admin_password = local.effective_admin_password
      manifest_b64 = base64encode(jsonencode({
        admin = {
          username = var.guacamole_admin_user
          password = local.effective_admin_password
        }
        autoregister = true
        connections  = []
        students     = []
      }))
      guac_fqdn       = local.effective_fqdn != null ? local.effective_fqdn : google_compute_address.guac.address
      guac_acme_email = var.acme_email
      ssh_pubkey      = var.operator_ssh_pubkey

      # Wildcard cert / KV path OFF for the shared-Guac MVP. The
      # userdata's feature-detection sees these empty and falls back
      # to HTTP-01. Same approach as envs/shared-guac-azure.
      guac_wildcard_zone     = ""
      guac_wildcard_zone_rg  = ""
      guac_wildcard_zone_sub = ""
      guac_kv_name           = ""
    })
  }

  tags = ["guacamole"]

  labels = local.common_labels

  allow_stopping_for_update = true

  # Same rationale as the per-range Guac: a userdata rewrite in the
  # cloud-init template should not force-replace a running Guac box —
  # destroying it would wipe the registered RDP connection list + the
  # LE cert state. Re-apply userdata changes via the future Ansible
  # role (`./range guac repair`).
  lifecycle {
    ignore_changes = [
      metadata["user-data"],
      labels["created"],
      description,
    ]
  }

  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.nat,
  ]
}
