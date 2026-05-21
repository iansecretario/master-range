################################################################################
# Variables for the shared-guac module.
################################################################################

variable "name" {
  description = "Logical name for this shared Guac deployment (used in resource names + tags). Default 'shared-guac'."
  type        = string
  default     = "shared-guac"
}

variable "azure_region" {
  description = "Azure region. Pick the one closest to your students/operators to minimize RDP latency."
  type        = string
  default     = "southeastasia"
}

variable "vm_size" {
  description = "Guacamole VM SKU. B4ms (4 vCPU, 16 GB) comfortably handles ~30-50 concurrent students. Bump to Standard_D4s_v5 if you hit CPU saturation, or D8s_v5 for 80+ concurrent."
  type        = string
  default     = "Standard_B4ms"
}

variable "admin_user" {
  description = "Guacamole admin username. Stays put for the life of the shared Guac — students don't see this account."
  type        = string
  default     = "guacadmin"
}

variable "admin_password" {
  description = "Guacamole admin password. Empty = generate a 28-char random password (recommended)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "login_title" {
  description = "Wordmark displayed on the Guacamole login page. Replaces the default 'APACHE GUACAMOLE'."
  type        = string
  default     = "Guidem CWR — Shared Range Portal"
}

variable "operator_username" {
  description = "Super-admin username for the operator (e.g. 'cwr-ian'). Auto-granted READ on every range that registers into this shared Guac. NOTE: in this Phase 2A skeleton, the actual multi-range super-admin auto-grant is performed by range apply (Phase 2B) — for now the admin_user above has full power."
  type        = string
  default     = "cwr-ian"
}

# ---- Public ingress -------------------------------------------------------
# Same shape as modules/azure/variables.tf::guacamole_ingress_cidrs — a list
# of /N CIDRs the geofence + operator-IP-detect produce. Inbound 443 is
# allowed only from these. Outbound is unrestricted (Guac calls out to
# range spokes via peering).
variable "ingress_cidrs" {
  description = "List of CIDRs allowed inbound on 443 (Guac UI) and 80 (LE HTTP-01 challenge). Default 0.0.0.0/0 — TIGHTEN before going public."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---- TLS / custom domain --------------------------------------------------
variable "acme_email" {
  description = "ACME contact email for the Let's Encrypt cert. Used for renewal-reminder mail; doesn't have to receive challenge mail. LE rejects RFC2606-reserved domains (example.com etc) — supply a real address."
  type        = string
  default     = "admin@example.com"
}

variable "custom_hostname" {
  description = "Subdomain label for Guac's custom hostname (e.g. 'guac' → guac.cyberwarrange.com). Requires dns_zone_name. Empty = use the Azure-assigned cloudapp.azure.com FQDN."
  type        = string
  default     = "guac"
}

variable "dns_zone_name" {
  description = "Apex DNS zone in Azure DNS to attach Guac to (e.g. 'cyberwarrange.com'). The terraform run needs DNS Zone Contributor on this zone's RG/sub. Empty = no custom DNS."
  type        = string
  default     = ""
}

variable "dns_zone_resource_group" {
  description = "RG containing the dns_zone_name. Required when dns_zone_name is set."
  type        = string
  default     = ""
}

variable "dns_zone_subscription_id" {
  description = "Subscription ID containing the dns_zone_name (when it lives in a different sub than this deploy). Empty = same sub."
  type        = string
  default     = ""
}

# ---- Network ranges -------------------------------------------------------
# Deliberately far from per-range CIDRs (10.X.0.0/22 for X=4..252 — see
# modules/azure/students.tf). Picking 10.250.0.0/22 means future
# isolated-mode ranges at inst-01..inst-63 (10.4-10.252) won't collide.
variable "vnet_cidr" {
  description = "VNet CIDR for the shared Guac. Must not overlap with any range's hub or spoke CIDR (per-range ranges use 10.0..10.252 in /22 chunks)."
  type        = string
  default     = "10.250.0.0/22"
}

variable "subnet_cidr" {
  description = "Subnet inside the Guac VNet. /24 from vnet_cidr."
  type        = string
  default     = "10.250.0.0/24"
}

variable "static_ip" {
  description = "Static private IP for the Guac VM. Defaults to .20 inside subnet_cidr (mirrors per-range Guac convention)."
  type        = string
  default     = "10.250.0.20"
}

# ---- Tags + lifecycle -----------------------------------------------------
variable "tags" {
  description = "Tags applied to every resource in this module. Range=shared-guac is the convention used by ./range nuke / ./range health for resource discovery."
  type        = map(string)
  default = {
    Range = "shared-guac"
    Tier  = "shared-services"
  }
}
