################################################################################
# Variables for envs/shared-guac-gcp.
#
# Sister file to envs/shared-guac-azure/main.tf's inline `variable` blocks
# (split out into a dedicated file here for readability — the GCP env has
# more knobs because it also provisions its own project).
################################################################################

# ── Cohort metadata ───────────────────────────────────────────────────
# `cohort_name` is the operator-facing label for this deployment
# (equivalent to range_name on the per-range side). Used as the
# resource name prefix and as the seed for the deterministic
# auto-generated project ID.

variable "cohort_name" {
  description = "Cohort identifier for this shared Guac (e.g. 'cwr-2026q2'). Used as the resource name prefix; must be DNS-safe (lowercase, [-a-z0-9])."
  type        = string
  default     = "shared-guac"
}

# ── Project provisioning ──────────────────────────────────────────────
# Same one-project-per-deploy pattern as envs/gcp/main.tf. The shared
# Guac lives in its OWN long-lived project so it's not entangled with
# any per-range project's lifecycle.

variable "gcp_project_id" {
  description = "GCP project ID hosting the shared Guac. Empty = auto-generate from cohort_name + sha256 suffix (terraform creates it). Non-empty = use the pre-existing project (set gcp_create_project=false)."
  type        = string
  default     = ""
}

variable "gcp_create_project" {
  description = "Have terraform create + own the shared-Guac project (true) or use a pre-existing one (false). Requires roles/resourcemanager.projectCreator at the folder/org when true."
  type        = bool
  default     = true
}

variable "gcp_billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) that pays for the shared-Guac project. Required when gcp_create_project=true. Get it from `gcloud beta billing accounts list`."
  type        = string
  default     = ""
}

variable "gcp_parent_folder_id" {
  description = "GCP folder ID (numeric) to nest the shared-Guac project under. Empty = use gcp_parent_org_id instead."
  type        = string
  default     = ""
}

variable "gcp_parent_org_id" {
  description = "GCP organization ID (numeric) to nest the shared-Guac project under. Used only when gcp_parent_folder_id is empty."
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GCP region. Pick the one closest to your students/operators to minimize RDP latency."
  type        = string
  default     = "asia-southeast1" # Singapore — Azure southeastasia equivalent
}

# ── VM sizing ─────────────────────────────────────────────────────────

variable "vm_size" {
  description = "Guacamole VM machine type. e2-standard-4 (4 vCPU/16 GB) handles ~30-50 concurrent students. Bump to e2-standard-8 for 80+ concurrent."
  type        = string
  default     = "e2-standard-4"
}

# ── Guacamole admin + branding ────────────────────────────────────────

variable "guacamole_admin_user" {
  description = "Guacamole admin username. Stays put for the life of the shared Guac — students don't see this account."
  type        = string
  default     = "guacadmin"
}

variable "guacamole_admin_password" {
  description = "Guacamole admin password. Empty = generate a 28-char random password (recommended)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "login_title" {
  description = "Wordmark displayed on the Guacamole login page (replaces default 'APACHE GUACAMOLE'). Baked into the Guac webapp by the Ansible role at a later phase; for now informational only."
  type        = string
  default     = "Guidem CWR — Shared Range Portal"
}

# ── Public ingress ────────────────────────────────────────────────────

variable "guacamole_ingress_cidrs" {
  description = "List of CIDRs allowed inbound on :443 (Guac UI) and :80 (LE HTTP-01 challenge). Default 0.0.0.0/0 — TIGHTEN before going public. Chunked at 250 per rule to respect GCP's per-rule source-range cap."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── Custom DNS / TLS ──────────────────────────────────────────────────
# When dns_zone_name + custom_hostname are set, terraform creates an A
# record `<custom_hostname>.<dns_zone_name>` pointing at the Guac VM's
# external IP, AND cloud-init/certbot issues an LE cert against that
# FQDN via HTTP-01. Without DNS, the Guac is reachable only by bare
# public IP with a self-signed cert.
#
# UNLIKE Azure (which provides cloudapp.azure.com auto-FQDNs on every
# public IP), GCP has NO free auto-FQDN. Either configure dns_zone_name
# below, or accept the bare-IP/self-signed deployment.

variable "acme_email" {
  description = "ACME contact email for Let's Encrypt. Used for renewal-reminder mail; doesn't need to receive challenges. LE rejects RFC2606-reserved domains (example.com etc) — supply a real address."
  type        = string
  default     = "admin@example.com"
}

variable "custom_hostname" {
  description = "Subdomain label for Guac's custom hostname (e.g. 'guac' → guac.cyberwarrange.com). Requires dns_zone_name. Empty = no custom DNS, bare-IP access."
  type        = string
  default     = "guac"
}

variable "dns_zone_name" {
  description = "Apex DNS zone in Cloud DNS (e.g. 'cyberwarrange.com'). The terraform run needs roles/dns.admin on this zone's project. Empty = no custom DNS."
  type        = string
  default     = ""
}

variable "dns_zone_project_id" {
  description = "GCP project hosting the dns_zone_name. Empty = same project as gcp_project_id (auto-provisioned shared-Guac project). Usually you want this set to your long-lived 'host' project that owns the parent domain."
  type        = string
  default     = ""
}

# ── Network ranges ────────────────────────────────────────────────────
# Deliberately far from per-range CIDRs (10.X.0.0/22 for X=4..252 — see
# modules/azure/students.tf and modules/gcp/network.tf). Picking
# 10.250.0.0/22 means future isolated-mode ranges at inst-01..inst-63
# (10.4..10.252) won't collide.

variable "vnet_cidr" {
  description = "VPC CIDR for the shared Guac VPC. Must not overlap with any range's hub or spoke CIDR (per-range ranges use 10.0..10.252 in /22 chunks). Currently informational — GCP VPCs don't take an aggregate range, but documented here for parity with the Azure side + future Shared-VPC routing decisions."
  type        = string
  default     = "10.250.0.0/22"
}

variable "subnet_cidr" {
  description = "Subnet inside the shared-Guac VPC. /24 from vnet_cidr."
  type        = string
  default     = "10.250.0.0/24"
}

variable "static_ip" {
  description = "Static private IP for the Guac VM. Defaults to .20 inside subnet_cidr (mirrors per-range Guac convention)."
  type        = string
  default     = "10.250.0.20"
}

# ── Optional SSH access ───────────────────────────────────────────────
# Operator-supplied SSH pubkey planted on the Guac VM. When empty, only
# the admin_password path works (operators rarely SSH into the Guac
# directly — most admin is via the web UI).

variable "operator_ssh_pubkey" {
  description = "Operator SSH public key to plant on the Guac VM under user 'guacadmin'. Empty = no SSH key planted (admin_password is the only SSH path)."
  type        = string
  default     = ""
}
