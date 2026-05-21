################################################################################
# Advanced C2: Azure Front Door fronting per-student c2-redirector(s).
#
#   Internet -> AFD -> redirector (public IP) -> c2-server (Adaptix)
#                                              \-> c2-mythic (Mythic)
#
# Multi-redirector aware: a student template may have one redirector
# fronting Adaptix and another fronting Mythic. Each gets a different
# subdomain, drawn from a curated pool of plausible-looking SaaS / CDN
# style names so external observers see indistinguishable-from-real-
# infra DNS rather than "adaptix.your-domain".
#
# Subdomain selection:
#   - operator-supplied `callsign:` field on the redirector wins
#   - otherwise generator picks from local.afd_subdomain_pool with a
#     numeric suffix appended for global uniqueness
#
# AFD endpoint name and profile name follow the same plausible-naming
# rule, with overrides via var.advanced_c2.endpoint_name / profile_name.
################################################################################

locals {
  afd_enabled = var.advanced_c2.enabled

  # Every redirector that exists in the machine list when AFD is on.
  redirectors = local.afd_enabled ? {
    for m in var.machines :
    m.name => m
    if m.role == "c2-redirector"
  } : {}

  # Curated pool of plausible subdomain prefixes. Pick one per redirector,
  # append a numeric suffix for uniqueness.
  afd_subdomain_pool = [
    "cdn", "cdn-edge", "static", "assets", "media", "api", "app",
    "auth", "id", "sso", "portal", "gateway", "track", "pixel",
    "analytics", "metrics", "logs", "events", "webinar", "register",
    "newsletter", "mail", "news", "edge", "edge-prod", "fastedge",
    "content", "asset-edge", "web-edge", "api-edge", "cdn-prod",
  ]

  # AFD endpoint name pool — same idea, different bias toward
  # platform / edge / production sounding prefixes (the endpoint
  # appears as a CNAME target so it should look like infra not product).
  afd_endpoint_pool = [
    "prod-edge", "cdn-prod", "web-edge", "app-gateway", "api-prod",
    "static-cdn", "edge-prod", "content-cdn", "asset-edge", "fastedge",
    "prodcdn", "edge-platform", "cdn-platform", "web-platform",
  ]

  # Random shuffle picks; numeric suffix added for guaranteed uniqueness
  # within (global namespace for endpoint, custom-domain namespace for
  # subdomains).
  redirector_subdomain = local.afd_enabled ? {
    for idx, m in tolist([for k, v in local.redirectors : v]) :
    m.name => (
      m.callsign != ""
      ? m.callsign
      : "${random_shuffle.redirector_prefix[m.name].result[0]}-${format("%02d", idx + 1)}"
    )
  } : {}

  afd_endpoint_name_effective = (
    var.advanced_c2.endpoint_name != ""
    ? var.advanced_c2.endpoint_name
    : "${random_shuffle.endpoint_prefix.result[0]}-${random_string.endpoint_suffix.result}"
  )

  afd_profile_name_effective = (
    var.advanced_c2.profile_name != ""
    ? var.advanced_c2.profile_name
    : "${random_shuffle.profile_prefix.result[0]}-${random_string.profile_suffix.result}"
  )
}

# ---- random selectors ------------------------------------------------------
resource "random_shuffle" "redirector_prefix" {
  for_each     = local.redirectors
  input        = local.afd_subdomain_pool
  result_count = 1
  lifecycle {
    ignore_changes = [input, result_count]
  }
}

resource "random_shuffle" "endpoint_prefix" {
  input        = local.afd_endpoint_pool
  result_count = 1
  lifecycle {
    ignore_changes = [input, result_count]
  }
}

resource "random_shuffle" "profile_prefix" {
  input        = local.afd_endpoint_pool
  result_count = 1
  lifecycle {
    ignore_changes = [input, result_count]
  }
}

resource "random_string" "endpoint_suffix" {
  length  = 5
  special = false
  upper   = false
  lifecycle {
    ignore_changes = [length, special, upper]
  }
}

resource "random_string" "profile_suffix" {
  length  = 5
  special = false
  upper   = false
  lifecycle {
    ignore_changes = [length, special, upper]
  }
}

# ---- redirector public IPs (one per redirector when AFD is on) -----------
resource "azurerm_public_ip" "redirector" {
  for_each            = local.redirectors
  name                = "${var.range_name}-${each.key}-pip"
  location            = azurerm_resource_group.student[each.value.student_id].location
  resource_group_name = azurerm_resource_group.student[each.value.student_id].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ---- Front Door profile + endpoint -----------------------------------------
resource "azurerm_cdn_frontdoor_profile" "main" {
  count               = local.afd_enabled ? 1 : 0
  name                = local.afd_profile_name_effective
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "Standard_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  count                    = local.afd_enabled ? 1 : 0
  name                     = local.afd_endpoint_name_effective
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
}

# ---- per-redirector AFD endpoint -------------------------------------------
# One AFD endpoint per redirector — so each beacon callback hostname can
# be the endpoint's OWN *.azurefd.net default hostname instead of the
# operator's custom domain (`<sub>.${advanced_c2.domain}`). Beacon binary
# strings no longer leak the operator's DNS zone — only the AFD endpoint
# (Azure-owned CDN, shared by millions of legitimate tenants).
#
# The operator's custom domain still exists and CNAMEs to this endpoint
# as a browser-friendly fallback access path; it just isn't what the
# beacon config points at.
#
# Cost: $0. AFD bills per *profile*, not per endpoint — multiple
# endpoints in the same Standard profile are free.
#
# Naming reuses local.redirector_subdomain (the same stealth prefix the
# custom domain uses) so the endpoint becomes
# `<prefix>-<MS-16-char>.<zone>.azurefd.net` — shortest the operator side
# can make it. The 16-char Microsoft suffix is non-negotiable.
resource "azurerm_cdn_frontdoor_endpoint" "redirector" {
  for_each                 = local.redirectors
  name                     = local.redirector_subdomain[each.key]
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
}

# ---- per-redirector origin groups + origins --------------------------------
resource "azurerm_cdn_frontdoor_origin_group" "redirector" {
  for_each                 = local.redirectors
  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 2
  }

  health_probe {
    path                = "/"
    request_type        = "HEAD"
    protocol            = "Https"
    interval_in_seconds = 100
  }
}

resource "azurerm_cdn_frontdoor_origin" "redirector" {
  for_each                       = local.redirectors
  name                           = each.key
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.redirector[each.key].id
  enabled                        = true
  certificate_name_check_enabled = false
  host_name                      = azurerm_public_ip.redirector[each.key].ip_address
  origin_host_header             = "${local.redirector_subdomain[each.key]}.${var.advanced_c2.domain}"
  http_port                      = 80
  https_port                     = 443
  priority                       = 1
  weight                         = 1000
}

# ---- per-redirector custom domain ------------------------------------------
# When advanced_c2.domain changes (e.g. switching from
# enterprisestudio.com → enterprisesstudio.com), the custom_domain's
# host_name forces a replacement. AFD refuses to delete the old one
# while a route still references it ("still associated with a route").
# Two-pronged workaround so terraform handles the swap cleanly:
#   1. The resource `name` includes a short hash of advanced_c2.domain
#      — domain-change → new hash → new AFD resource name → terraform
#      sees it as a brand-new resource (no name collision when both
#      exist briefly).
#   2. lifecycle.create_before_destroy = true — new custom_domain is
#      provisioned FIRST, then the route's cdn_frontdoor_custom_domain_ids
#      list updates to swap in the new ID, then the old custom_domain
#      can be safely destroyed.
resource "azurerm_cdn_frontdoor_custom_domain" "redirector" {
  for_each                 = local.redirectors
  name                     = "${each.value.student_id != "" ? each.value.student_id : "single"}-${each.key}-${substr(md5(var.advanced_c2.domain), 0, 6)}-domain"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
  host_name                = "${local.redirector_subdomain[each.key]}.${var.advanced_c2.domain}"

  tls {
    certificate_type = "ManagedCertificate"
    minimum_version  = "TLS12"
  }

  lifecycle {
    # AFD custom_domains participate in the normal AFD lifecycle —
    # they're destroyed alongside the profile/endpoint/routes on
    # `./range destroy`. The cost is a 10-20 min managed-cert
    # revalidation on the next deploy, but it keeps the AFD config
    # consistent with the route + endpoint that get re-created.
    # `create_before_destroy` stays so domain-attribute changes
    # (e.g. swapping advanced_c2.domain) replace cleanly without
    # the "still associated with route" 400 we hit earlier.
    create_before_destroy = true
  }
}

resource "azurerm_cdn_frontdoor_route" "redirector" {
  for_each                      = local.redirectors
  name                          = "${each.value.student_id != "" ? each.value.student_id : "single"}-${each.key}-route"
  # Per-redirector endpoint (changed from the shared main endpoint).
  # Each route lives on its OWN endpoint so link_to_default_domain can
  # be `true` per endpoint without multi-route conflict on a shared
  # default hostname. This is what lets beacons callback to the
  # endpoint's *.azurefd.net default name directly — no operator
  # custom domain in their config.
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.redirector[each.key].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.redirector[each.key].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.redirector[each.key].id]
  cdn_frontdoor_custom_domain_ids = [
    azurerm_cdn_frontdoor_custom_domain.redirector[each.key].id,
  ]
  link_to_default_domain = true # beacons callback via endpoint hostname directly
  enabled                = true
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
}

# ---- Azure DNS automation (optional) --------------------------------------
# DNS zone may live in a separate subscription from the range deploy
# (e.g. shared corporate domain). All DNS reads/writes use the aliased
# `azurerm.dns` provider, which the env wires to the correct sub via
# advanced_c2.dns_zone_subscription_id. When that's empty, the alias
# falls through to the same sub as the deploy.
data "azurerm_dns_zone" "main" {
  provider            = azurerm.dns
  count               = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? 1 : 0
  name                = var.advanced_c2.domain
  resource_group_name = var.advanced_c2.dns_zone_resource_group
}

resource "azurerm_dns_txt_record" "validation" {
  provider            = azurerm.dns
  for_each            = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? local.redirectors : {}
  name                = "_dnsauth.${local.redirector_subdomain[each.key]}"
  zone_name           = data.azurerm_dns_zone.main[0].name
  resource_group_name = data.azurerm_dns_zone.main[0].resource_group_name
  ttl                 = 3600

  record {
    value = azurerm_cdn_frontdoor_custom_domain.redirector[each.key].validation_token
  }
  # NOTE: no lifecycle protection — this TXT is bound to the AFD
  # custom_domain's validation_token. When custom_domain is destroyed
  # (e.g. `./range destroy`), the token reference goes away; the TXT
  # is destroyed alongside it. Re-deploys generate a fresh token + TXT.
}

resource "azurerm_dns_cname_record" "redirector" {
  provider            = azurerm.dns
  for_each            = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? local.redirectors : {}
  name                = local.redirector_subdomain[each.key]
  zone_name           = data.azurerm_dns_zone.main[0].name
  resource_group_name = data.azurerm_dns_zone.main[0].resource_group_name
  ttl                 = 300
  # Point the custom-domain CNAME at the PER-REDIRECTOR endpoint (the
  # new architecture), not at the shared main endpoint (which has no
  # routes attached now and would 404 any traffic). Custom domain stays
  # as a browser-friendly fallback; beacons callback to the endpoint
  # hostname directly without traversing this CNAME.
  record              = azurerm_cdn_frontdoor_endpoint.redirector[each.key].host_name

  depends_on = [azurerm_dns_txt_record.validation]
  # No lifecycle protection — the CNAME points at AFD's endpoint
  # host_name, which is regenerated on destroy/recreate. Keeping the
  # record sticky here would pin DNS at a dead endpoint after destroy.
  # Let it follow the AFD lifecycle.
}

# AFD's managed-cert flow runs ASYNCHRONOUSLY after the route + custom
# domain + DNS records all exist. Terraform considers the resources
# "created" the moment Azure returns 200 to the PUT, but the cert isn't
# actually issued until AFD polls the TXT record (5–15 min typically).
# During that window HTTPS to the custom domain returns errors and
# beacons fail.
#
# This time_sleep blocks `terraform apply` from returning until that
# window is comfortably closed. Set
# `advanced_c2_validation_wait_minutes = 0` in your scenario or via
# -var to skip if you'd rather poll yourself with `./range afd-status`.
# ============================================================================
# DoH (DNS-over-HTTPS) leg
# ============================================================================
# When advanced_c2.dns_listeners is non-empty, each entry creates an
# additional AFD custom domain + route for the DoH stealth hostname.
# Beacons POST DoH requests to https://<doh-hostname>/dns-query; AFD
# routes through to nginx on the assigned redirector, which path-routes
# /dns-query into a sidecar dnsdist (DoH → raw DNS) → C2's DNS listener
# on internal :5353. Wire transport is HTTPS, so DoH traffic rides AFD
# anycast — the C2's DNS listener IP is never publicly exposed.
#
# Optional dedicated-profile mode: when advanced_c2.dns_dedicated_afd_profile
# is true, DoH spins up its OWN azurerm_cdn_frontdoor_profile + endpoint
# instead of sharing the HTTPS C2 profile. Costs ~$35/mo extra (the
# extra profile is billed independently); gives a different anycast IP
# + separate billing surface, so flagging events on the HTTPS profile
# don't propagate to the DoH path.
locals {
  # DoH listeners requested. Keyed by C2 role name (sliver | mythic |
  # adaptix | brc4); value is the DoH stealth hostname under
  # advanced_c2.domain.
  doh_listeners = local.afd_enabled ? var.advanced_c2.dns_listeners : {}

  # Whether to use a dedicated AFD profile/endpoint for DoH.
  doh_dedicated = local.afd_enabled && var.advanced_c2.dns_dedicated_afd_profile && length(var.advanced_c2.dns_listeners) > 0

  # The redirector that DoH custom-domain routes attach to. v1: first
  # redirector in local.redirectors handles all DoH (operator configures
  # its nginx to route to the right C2 by DoH-hostname matching — same
  # pattern the HTTPS leg already uses). Future enhancement: per-C2
  # redirector pinning via a c2_target field on each redirector machine
  # in the scenario YAML.
  doh_primary_redirector = (
    length(local.redirectors) > 0
    ? keys(local.redirectors)[0]
    : ""
  )

  # Profile + endpoint IDs that DoH custom_domains/routes attach to:
  # dedicated when the flag is set, otherwise the shared main AFD.
  doh_profile_id = (
    local.doh_dedicated
    ? azurerm_cdn_frontdoor_profile.doh[0].id
    : (local.afd_enabled ? azurerm_cdn_frontdoor_profile.main[0].id : "")
  )
  doh_endpoint_id = (
    local.doh_dedicated
    ? azurerm_cdn_frontdoor_endpoint.doh[0].id
    : (local.afd_enabled ? azurerm_cdn_frontdoor_endpoint.main[0].id : "")
  )
  doh_endpoint_host_name = (
    local.doh_dedicated
    ? azurerm_cdn_frontdoor_endpoint.doh[0].host_name
    : (local.afd_enabled ? azurerm_cdn_frontdoor_endpoint.main[0].host_name : "")
  )
}

# Dedicated AFD profile for DoH (only when dns_dedicated_afd_profile = true).
resource "azurerm_cdn_frontdoor_profile" "doh" {
  count               = local.doh_dedicated ? 1 : 0
  name                = "${local.afd_profile_name_effective}-doh"
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "Standard_AzureFrontDoor"
}

resource "azurerm_cdn_frontdoor_endpoint" "doh" {
  count                    = local.doh_dedicated ? 1 : 0
  name                     = "${local.afd_endpoint_name_effective}-doh"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.doh[0].id
}

# Per-listener DoH custom domain.
resource "azurerm_cdn_frontdoor_custom_domain" "doh" {
  for_each = local.doh_listeners

  name                     = "doh-${each.key}-${substr(md5(each.value), 0, 6)}-domain"
  cdn_frontdoor_profile_id = local.doh_profile_id
  host_name                = each.value

  tls {
    certificate_type = "ManagedCertificate"
    minimum_version  = "TLS12"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Per-listener DoH route. patterns_to_match = ["/*"] (same as HTTPS leg).
# The /dns-query path-routing is handled at nginx on the redirector, NOT
# at AFD. nginx differentiates /dns-query (→ dnsdist on 127.0.0.1:8053)
# from beacon C2 paths (→ C2 HTTPS) from cover-page fallback (→ 302 to
# advanced_c2.cover_url). AFD just forwards everything verbatim.
resource "azurerm_cdn_frontdoor_route" "doh" {
  for_each = local.doh_listeners

  name                          = "doh-${each.key}-route"
  cdn_frontdoor_endpoint_id     = local.doh_endpoint_id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.redirector[local.doh_primary_redirector].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.redirector[local.doh_primary_redirector].id]
  cdn_frontdoor_custom_domain_ids = [
    azurerm_cdn_frontdoor_custom_domain.doh[each.key].id,
  ]
  link_to_default_domain = false
  enabled                = true
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
}

# Azure DNS records for DoH custom domains (TXT validation + CNAME).
# Same pattern as the HTTPS leg's validation + CNAME records.
resource "azurerm_dns_txt_record" "doh_validation" {
  provider = azurerm.dns
  for_each = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? local.doh_listeners : {}

  # Extract the leaf label from the DoH FQDN — e.g., "cdn-eu1" from
  # "cdn-eu1.enterprisesstudio.com" — for the _dnsauth.<label> TXT name.
  name                = "_dnsauth.${trimsuffix(each.value, ".${var.advanced_c2.domain}")}"
  zone_name           = data.azurerm_dns_zone.main[0].name
  resource_group_name = data.azurerm_dns_zone.main[0].resource_group_name
  ttl                 = 3600

  record {
    value = azurerm_cdn_frontdoor_custom_domain.doh[each.key].validation_token
  }
}

resource "azurerm_dns_cname_record" "doh" {
  provider = azurerm.dns
  for_each = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? local.doh_listeners : {}

  name                = trimsuffix(each.value, ".${var.advanced_c2.domain}")
  zone_name           = data.azurerm_dns_zone.main[0].name
  resource_group_name = data.azurerm_dns_zone.main[0].resource_group_name
  ttl                 = 300
  record              = local.doh_endpoint_host_name

  depends_on = [azurerm_dns_txt_record.doh_validation]
}

# ---- AFD managed-cert validation wait --------------------------------------
# Blocks `terraform apply` until AFD has had time to validate the TXT
# records and issue managed certs for ALL custom domains — both the
# HTTPS C2 leg's redirector domains AND any DoH leg domains we just
# created. Validation is async after Azure returns 200 on the resource
# PUTs; typical 5-15 min, defensive default 20 min.
resource "time_sleep" "afd_validation_wait" {
  count = local.afd_enabled && var.advanced_c2_validation_wait_minutes > 0 ? 1 : 0

  create_duration = "${var.advanced_c2_validation_wait_minutes}m"

  depends_on = [
    azurerm_cdn_frontdoor_route.redirector,
    azurerm_cdn_frontdoor_custom_domain.redirector,
    azurerm_dns_txt_record.validation,
    azurerm_dns_cname_record.redirector,
    azurerm_cdn_frontdoor_route.doh,
    azurerm_cdn_frontdoor_custom_domain.doh,
    azurerm_dns_txt_record.doh_validation,
    azurerm_dns_cname_record.doh,
  ]
}
