################################################################################
# Outputs — what range applies need to find this shared Guac and
# register their connections into it.
#
# Sister file to envs/shared-guac-azure/main.tf's inline `output` blocks
# (split out into a dedicated file here for readability).
#
# Future Phase 2B work: range applies (envs/gcp/ for cohort deploys)
# will pull these values via `terraform_remote_state` pointing at this
# env's backend. Field names here form the cross-deploy contract;
# changing them requires updating every consumer simultaneously.
################################################################################

# ── Operator-facing entry-point ───────────────────────────────────────

output "guac_url" {
  description = "HTTPS URL operators + students use to reach the shared Guacamole UI. Resolves to the custom FQDN when dns_zone_name + custom_hostname are configured, else falls back to the bare public IP."
  value       = "https://${local.effective_fqdn != null ? local.effective_fqdn : google_compute_address.guac.address}"
}

output "fqdn" {
  description = "Bare hostname (no scheme). Null when no custom DNS is configured — consumers should coalesce to public_ip in that case."
  value       = local.effective_fqdn
}

output "guac_public_ip" {
  description = "Static external IP of the Guac VM. Useful for adding to firewall allow-lists on cohort projects, manual DNS A-record verification, etc."
  value       = google_compute_address.guac.address
}

output "guac_private_ip" {
  description = "Static private IP of the Guac VM inside the shared-Guac VPC (default 10.250.0.20). Range hosts in peered VPCs reach the Guac at this address for the back-channel."
  value       = var.static_ip
}

# ── Credentials ───────────────────────────────────────────────────────

output "admin_user" {
  description = "Admin username for the shared Guac (default 'guacadmin'). Used by range applies to authenticate to the REST API for connection registration (Phase 2B)."
  value       = var.guacamole_admin_user
}

output "admin_password" {
  description = "Admin password for the shared Guac. Either the operator-supplied value (when guacamole_admin_password is set) or the random_password generated at apply time."
  value       = local.effective_admin_password
  sensitive   = true
}

# ── Network handles for Phase 2B peering ──────────────────────────────
# Range applies will add a VPC PEERING (google_compute_network_peering)
# between their cohort VPC and this Guac's VPC so the shared Guac can
# reach each cohort's private IPs over the RDP/SSH back-channel.

output "vpc_id" {
  description = "Resource ID of the shared-Guac VPC. Range applies create a peering on their cohort VPC pointing at this id."
  value       = google_compute_network.guac.id
}

output "vpc_name" {
  description = "Name of the shared-Guac VPC. Some peering operations need name+project rather than id."
  value       = google_compute_network.guac.name
}

output "vpc_self_link" {
  description = "Self-link of the shared-Guac VPC (https://www.googleapis.com/compute/v1/projects/.../global/networks/...). google_compute_network_peering takes this in its `network` argument."
  value       = google_compute_network.guac.self_link
}

output "gcp_project_id" {
  description = "GCP project ID this shared Guac runs in. Range applies pass this to their peering resource so cross-project peering authorizes both sides."
  value       = local.effective_project_id
}

output "gcp_region" {
  description = "GCP region the shared Guac runs in."
  value       = var.gcp_region
}
