################################################################################
# Cloud NAT for egress. Mirrors modules/azure/students.tf's per-student
# `azurerm_nat_gateway` block. One Cloud Router + one Cloud NAT for the
# entire VPC (NOT per-student) because:
#
#   - Cloud NAT is a regional service and scales horizontally. One NAT
#     covers every subnet in the region with no extra per-student
#     plumbing.
#   - Each NAT IP can absorb ~64 concurrent connections per destination
#     IP-port. Auto-allocate mode adds IPs as load demands; manual mode
#     pins specific reserved IPs (cheaper outbound consistency).
#   - Free-tier limit: ≤8 VMs per NAT IP. Auto-allocate handles this
#     transparently; you only pay for data transferred + the public IPs
#     allocated.
#
# Lockdown semantics: when var.lockdown == true, the Cloud NAT is NOT
# created — VMs without an external IP lose all internet egress.
# Combined with the egress deny rule in firewall.tf, this gives the
# Azure-equivalent "post-build network isolation" behaviour.
#
# Workflow:
#   1. ./range gen <scenario>                  # lockdown=false (default)
#   2. terraform apply                          # NAT created → cloud-init/CSE
#                                              # fetch packages
#   3. ./range lockdown                         # flips lockdown=true
#   4. terraform apply                          # NAT destroyed → egress dies
################################################################################

# Cloud Router. Required parent for Cloud NAT (even though we don't
# run dynamic routing — the router is just the NAT control plane).
resource "google_compute_router" "nat" {
  count = var.lockdown ? 0 : 1

  name        = "${var.range_name}-nat-router"
  project     = var.gcp_project_id
  region      = var.azure_region
  network     = google_compute_network.hub.id
  description = "Cloud NAT control-plane router for ${var.range_name}. No BGP — NAT use only."
}

# Cloud NAT. Single instance covering every subnet in the VPC (hub +
# every student spoke). Auto-allocates NAT IPs as VM count grows.
resource "google_compute_router_nat" "nat" {
  count = var.lockdown ? 0 : 1

  name                               = "${var.range_name}-nat"
  project                            = var.gcp_project_id
  region                             = var.azure_region
  router                             = google_compute_router.nat[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Default port allocations (64 per VM, 30s UDP / 1200s TCP-established
  # timeouts). Tune these if a high-connection workload (e.g. mass HTTP
  # scanning from kali) exhausts the per-VM port budget — symptom is
  # "NAT allocation failed" entries in Cloud Logging.
  min_ports_per_vm = 64

  # Surface NAT logs for debugging. ERRORS_ONLY keeps cost low; flip to
  # ALL during initial bring-up to verify every VM is egressing through
  # the NAT (not via an attached external IP).
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

  # endpoint_independent_mapping = false is the default; we leave it
  # explicit-default so a future operator reading this file knows the
  # mode without diving into provider docs. EIM=false means each
  # destination gets its own ephemeral src port — better for connection
  # tracking, slightly higher port consumption.
}
