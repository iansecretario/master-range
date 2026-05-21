################################################################################
# External HTTPS Load Balancer + Cloud CDN — provider-equivalent of
# modules/azure/frontdoor.tf. Routes operator-fronted C2 callback traffic
# through a managed-cert frontend, then to per-stack backend services
# pointing at the c2-redirector VMs.
#
# Phase A status: STUB resources with `count = 0` so outputs.tf can
# reference google_compute_global_forwarding_rule.main + .address.main
# without "Reference to undeclared resource" failures. The full
# implementation (frontend cert + URL map + backend services + Cloud CDN
# + Cloud Armor + DNS record) lands in Phase D.
#
# Why stubs vs deferring outputs.tf rewrites:
#   - outputs.tf needs to expose advanced_c2 metadata to ansible inventory
#     even when the LB isn't built yet (returns null fields). Easier to
#     keep the count=0 stubs here than to gut outputs.tf and re-add when
#     Phase D lands.
################################################################################

# Reserved global anycast IP for the external HTTPS LB frontend.
# Phase A: count=0 (no resource created). Phase D: count = var.advanced_c2.enabled ? 1 : 0.
resource "google_compute_global_address" "main" {
  count        = 0
  name         = "${local.range_prefix}-c2-frontend-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# Global forwarding rule binding the global IP above to a target HTTPS
# proxy. Phase A: count=0. Phase D: actual LB frontend.
resource "google_compute_global_forwarding_rule" "main" {
  count                 = 0
  name                  = "${local.range_prefix}-c2-fwd-https"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  ip_address            = google_compute_global_address.main[0].address
  # target = google_compute_target_https_proxy.main[0].id  ← Phase D
  target = ""
}

# Per-redirector metadata locals consumed by outputs.tf (advanced_c2 +
# ansible_inventory blocks). Phase A: empty maps so outputs return empty
# lists. Phase D will populate these with one entry per c2-redirector.
locals {
  # Map of redirector machine.name → machine entry. Empty when LB isn't
  # configured; outputs.tf wraps reads in try(local.redirectors, {}).
  redirectors = {}

  # Per-redirector subdomain assignment (e.g. "api-edge-01", "news-02")
  # prefixed onto the LB FQDN. Empty in Phase A; populated in Phase D
  # from the same algorithm Azure uses (frontdoor.tf:redirector_subdomain).
  redirector_subdomain = {}

  # AFD-equivalent flag — true when the external HTTPS LB + Cloud CDN
  # stack is provisioned. Phase A: always false (count = 0 on the LB
  # resources above). Phase D: `var.advanced_c2.enabled` + actually
  # provision the LB. outputs.tf reads this via try(local.afd_enabled, false).
  afd_enabled = false
}
