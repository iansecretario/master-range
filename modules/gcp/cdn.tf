################################################################################
# External HTTPS Load Balancer + Cloud CDN + Cloud Armor — provider-equivalent
# of modules/azure/frontdoor.tf.
#
#   Internet -> Anycast IP -> Global HTTPS LB -> URL map -> per-redirector
#                                                          backend service ->
#                                                          c2-redirector VM
#                                                          (public IP, :443)
#
# Mapping to Azure AFD primitives:
#   azurerm_cdn_frontdoor_profile     -> implicit; Cloud CDN attaches to
#                                        backend services, no profile object.
#   azurerm_cdn_frontdoor_endpoint    -> google_compute_url_map host_rules
#                                        + google_dns_record_set (A record).
#   azurerm_cdn_frontdoor_origin_grp  -> google_compute_backend_service.
#   azurerm_cdn_frontdoor_origin      -> google_compute_instance_group
#                                        (unmanaged single-instance NEG-equiv).
#   azurerm_cdn_frontdoor_route       -> google_compute_url_map.path_matcher.
#   azurerm_cdn_frontdoor_custom_dom  -> google_compute_managed_ssl_certificate
#                                        (one cert, many SANs).
#   azurerm_cdn_frontdoor_firewall    -> google_compute_security_policy
#                                        (Cloud Armor, header-check expression).
#
# Differences vs the Azure side worth knowing:
#   * Single global anycast IP fronts EVERY redirector; URL-map host
#     rules dispatch by Host header, NOT per-endpoint Microsoft hostnames.
#     Trade-off: GCP doesn't give us per-endpoint *.cdn.google.com names,
#     so beacons must callback to <subdomain>.<advanced_c2.domain> — the
#     custom domain IS the wire identity. The operator's DNS zone is in
#     beacon configs (same as the AWS CloudFront port).
#   * One Cloud-managed SSL cert with one SAN per redirector subdomain
#     (vs Azure's one managed cert per AFD custom domain). Cheaper to
#     reason about, but a single cert provisioning failure blocks ALL
#     subdomains. Managed SSL certs validate via DNS automatically once
#     the A records resolve to the LB's IP (10-30 min typical).
#   * Cloud Armor enforces the FDID-equivalent header at the LB edge
#     before the request reaches the redirector — Azure pushes that
#     validation into the redirector's nginx via AFD's WAF rule.
################################################################################

locals {
  afd_enabled = var.advanced_c2.enabled

  # Per-redirector machine map. Same shape as Azure's local.redirectors
  # but built directly from var.machines here so we don't have to thread
  # an extra local through. Only redirectors that actually FRONT a C2
  # are included; a redirector with `fronts: ""` is misconfigured and
  # excluded so we don't issue a cert SAN for a backend that won't exist.
  redirectors = local.afd_enabled ? {
    for m in var.machines :
    m.name => m
    if m.role == "c2-redirector" && m.fronts != ""
  } : {}

  # Per-redirector subdomain label (no apex). Goes into the cert SAN list,
  # the DNS A record, and the URL-map host rules.
  #
  # Subdomain selection precedence (mirrors Azure's frontdoor.tf):
  #   1. operator-provided `callsign:` on the machine
  #   2. else: format string from advanced_c2.student_subdomain_format,
  #      with {sid}/{fronts}/{idx} substitutions
  #   3. final fallback: machine name (deterministic, debuggable)
  redirector_subdomain = local.afd_enabled ? {
    for name, m in local.redirectors :
    name => (
      m.callsign != ""
      ? m.callsign
      : (
        var.advanced_c2.student_subdomain_format != ""
        ? replace(
          replace(
            replace(
              var.advanced_c2.student_subdomain_format,
              "{sid}", m.student_id != "" ? m.student_id : "single",
            ),
            "{fronts}", m.fronts,
          ),
          "{idx}", format("%02d", m.student_index),
        )
        : name
      )
    )
  } : {}

  # Per-redirector FQDN — the public name beacons resolve. The SSL cert
  # gets one SAN per FQDN; DNS A records map each one back to the LB's
  # anycast IP. Same value gets used as the Host header in URL-map
  # host_rules.
  redirector_fqdn = {
    for name in keys(local.redirectors) :
    name => "${local.redirector_subdomain[name]}.${var.advanced_c2.domain}"
  }

  # FDID-equivalent header. Cloud Armor enforces this at the LB edge so
  # direct-to-redirector probes that find the public IP (and bypass the
  # CDN) get a 403 from nginx (separate enforcement layer — see
  # firewall.tf), and CDN-shaped probes missing the header get a 403
  # from Cloud Armor here. The token is a per-deploy shared secret —
  # all redirectors in this range share the same FDID.
  #
  # `local.cdn_headers` lives in passwords.tf and has shape
  #   { stack => { student_id => { cdn => {name, value, port} } } }
  # We arbitrarily pick the first student's adaptix-azure UUID as the
  # FDID value — it's a 36-char UUID with the same randomness profile
  # as a dedicated random_uuid would have, and avoids declaring an
  # extra resource. Falls back to an empty string when AFD is disabled
  # or the student list is empty (Cloud Armor policy isn't created
  # in those cases either, so the value is unused).
  # Filter out the "" student_id used by per_student=false shared machines
  # in multi-student shared-mode deploys — those don't appear as keys in
  # local.cdn_headers (cdn_headers only spans real student_ids).
  _real_students = sort([for sid in local.students : sid if sid != ""])
  _first_student = length(local._real_students) > 0 ? local._real_students[0] : ""
  fdid_token = (
    local.afd_enabled && local._first_student != ""
    ? local.cdn_headers["adaptix"][local._first_student]["azure"].value
    : ""
  )

  # LB name root. Operator can override via advanced_c2.endpoint_name;
  # default to a stable derived name so terraform doesn't churn on
  # re-applies.
  lb_name = (
    var.advanced_c2.endpoint_name != ""
    ? var.advanced_c2.endpoint_name
    : "${local.range_prefix}-c2"
  )
}

# ============================================================================
# Frontend — reserved global anycast IP, managed SSL cert, HTTPS proxy,
# global forwarding rule on :443.
# ============================================================================

resource "google_compute_global_address" "main" {
  count        = local.afd_enabled ? 1 : 0
  name         = "${local.range_prefix}-c2-frontend-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
  description  = "Anycast IP for the global HTTPS LB fronting c2-redirectors. Beacon callback DNS resolves to this address."
}

# One Cloud-managed SSL cert with N SANs (one per redirector FQDN).
# Validation is DNS-01 against the A records google_dns_record_set.redirector
# creates below, run asynchronously by Google's PKI plumbing — no terraform
# polling, no time_sleep block. Provisioning takes 10–30 min after the LB
# is reachable; the first apply will surface PROVISIONING state on the cert
# until then. Operators can poll with
#   gcloud compute ssl-certificates describe <cert-name> --global
# to watch the per-SAN status flip from PROVISIONING -> ACTIVE.
#
# We rotate cert names on SAN list changes (md5 of sorted FQDNs in the
# name) because google_compute_managed_ssl_certificate's `managed.domains`
# is force-new — terraform must delete the old cert and create a new one.
# Including the hash in the name gives create_before_destroy semantics
# (briefly two certs exist while the LB swaps over).
resource "google_compute_managed_ssl_certificate" "main" {
  count = local.afd_enabled && length(local.redirectors) > 0 ? 1 : 0
  name = format(
    "%s-c2-cert-%s",
    local.range_prefix,
    substr(md5(join(",", sort(values(local.redirector_fqdn)))), 0, 6),
  )
  description = "Managed SSL cert for c2-redirector subdomains. SAN list rotates via name hash when redirector set changes."
  managed {
    domains = values(local.redirector_fqdn)
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "main" {
  count   = local.afd_enabled && length(local.redirectors) > 0 ? 1 : 0
  name    = "${local.range_prefix}-c2-https-proxy"
  url_map = google_compute_url_map.main[0].id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.main[0].id,
  ]
  description = "HTTPS target proxy binding the managed cert to the c2 URL map."
}

resource "google_compute_global_forwarding_rule" "main" {
  count = local.afd_enabled && length(local.redirectors) > 0 ? 1 : 0
  # Honors var.advanced_c2.endpoint_name when set, else falls back to
  # the derived "${range}-c2" base name. Operator overrides through
  # the scenario YAML's advanced_c2.endpoint_name field.
  name                  = "${local.lb_name}-fwd-https"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  ip_address            = google_compute_global_address.main[0].address
  target                = google_compute_target_https_proxy.main[0].id
}

# ============================================================================
# URL map — host-based routing, one path matcher per redirector.
#
# default_service catches anything that doesn't match a host rule (e.g.
# direct-to-IP probes that bypass DNS, or wrong Host headers from
# enumeration scanners). We route those to the first redirector backend
# so cover-page semantics are still served by nginx — same effect as
# Azure's "cover-redirect for missing headers" AFD rule. The redirector
# nginx config 302s anything without a valid X-Api-* header to
# var.advanced_c2.cover_url, so the default_service path produces the
# same operator-cover behavior.
# ============================================================================

resource "google_compute_url_map" "main" {
  count       = local.afd_enabled && length(local.redirectors) > 0 ? 1 : 0
  name        = "${local.range_prefix}-c2-urlmap"
  description = "Host-based routing — one path matcher per c2-redirector subdomain."

  # Pick the first redirector deterministically as the fallback. sort()
  # keeps the choice stable across re-applies (no churn from map iteration
  # order changes).
  default_service = google_compute_backend_service.redirector[
    sort(keys(local.redirectors))[0]
  ].id

  dynamic "host_rule" {
    for_each = local.redirectors
    content {
      hosts        = [local.redirector_fqdn[host_rule.key]]
      path_matcher = "pm-${host_rule.key}"
    }
  }

  dynamic "path_matcher" {
    for_each = local.redirectors
    content {
      name = "pm-${path_matcher.key}"
      default_service = google_compute_backend_service.redirector[
        path_matcher.key
      ].id
    }
  }
}

# ============================================================================
# Backend — per-redirector instance group + health check + backend service.
# Cloud CDN enabled inline on each backend service (no separate resource).
# ============================================================================

# Health check. Cloud LB requires one per backend service; we share a
# single check across all redirector backends because they're all the
# same nginx-on-Debian shape with the same /healthz endpoint.
resource "google_compute_health_check" "redirector" {
  count = local.afd_enabled && length(local.redirectors) > 0 ? 1 : 0
  name  = "${local.range_prefix}-c2-redirector-hc"

  check_interval_sec  = 30
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  # nginx on the redirector serves /healthz on :80 over HTTP (cheap; no
  # cert plumbing inside the health-check path). The same nginx also
  # serves :443 to beacons over HTTPS — the LB-to-origin link uses the
  # backend service's protocol setting below, not the health check.
  http_health_check {
    port         = 80
    request_path = "/healthz"
  }

  description = "Shared health check for all c2-redirector backends; nginx exposes /healthz on :80."
}

# Unmanaged instance group per redirector. Single-instance groups are
# the GCP idiom for "I have one VM, attach it to an LB". Equivalent to
# Azure's behavior of just dropping a redirector public IP as an AFD
# origin — GCP requires the instance to be wrapped in an instance group
# before a backend service can target it.
resource "google_compute_instance_group" "redirector" {
  for_each  = local.afd_enabled ? local.redirectors : {}
  name      = "${local.range_prefix}-${each.key}-ig"
  zone      = local.machine_zone[each.key]
  instances = [google_compute_instance.linux[each.key].id]

  named_port {
    name = "https"
    port = 443
  }

  description = "Single-instance group wrapping ${each.key} for backend-service attachment."
}

# Per-redirector backend service. Cloud CDN is enabled inline. The
# Cloud Armor security policy attaches here too — header-validation
# happens at the LB edge before the request hits the redirector.
resource "google_compute_backend_service" "redirector" {
  for_each = local.afd_enabled ? local.redirectors : {}
  name     = "${local.range_prefix}-${each.key}-bes"
  protocol = "HTTPS" # LB-to-origin uses HTTPS; cert mismatch tolerated
  # because the redirector serves a self-signed cert
  # (operator nginx). GCP LB origin TLS validation
  # against backend certs requires a backend_service-
  # bound CA bundle which we don't currently provision.
  port_name             = "https"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"

  # Cloud CDN — disabled by default for C2 fronting because beacon
  # traffic isn't cacheable and caching would corrupt session state.
  # The block exists for parity with Azure AFD's "CDN" surface; flip
  # to true if you want static cover-page assets cached. The other
  # 99% of beacon traffic is POST/dynamic and is never cached anyway.
  enable_cdn = false

  health_checks = [
    google_compute_health_check.redirector[0].id,
  ]

  backend {
    group           = google_compute_instance_group.redirector[each.key].id
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  # Cloud Armor edge filtering — same security_policy applies to every
  # backend. count=0 when fdid_header_required=false so the policy
  # doesn't exist; we set security_policy=null in that case.
  security_policy = (
    var.advanced_c2.fdid_header_required && length(google_compute_security_policy.fdid_check) > 0
    ? google_compute_security_policy.fdid_check[0].id
    : null
  )

  description = "Backend service for redirector ${each.key} (fronts ${each.value.fronts})."
}

# ============================================================================
# Cloud Armor — FDID header validation at the LB edge.
#
# Default rule (priority 2147483647) DENIES with 403 for any request
# whose `x-fdid` header is missing or doesn't match the per-deploy
# token. The single allow rule (priority 1000) ALLOWS when the header
# matches.
#
# This is the AFD-WAF equivalent of "covered redirect for missing
# headers" — except instead of redirecting to var.advanced_c2.cover_url,
# we deny outright at the edge. The redirector's nginx still does the
# 302-to-cover-URL on the SECOND header check (X-Api-* matches a real
# CDN slot), so a request that passes Cloud Armor but lacks the
# per-CDN nginx header still gets the cover page — two layers of
# header validation, same operator UX as Azure.
#
# When fdid_header_required=false the policy is not created and
# security_policy=null on the backend services, so all traffic that
# reaches the LB is forwarded to the redirector (and nginx handles
# the validation itself).
# ============================================================================

resource "google_compute_security_policy" "fdid_check" {
  count = local.afd_enabled && var.advanced_c2.fdid_header_required && length(local.redirectors) > 0 ? 1 : 0
  name  = "${local.range_prefix}-c2-fdid-policy"

  description = "Cloud Armor — enforce the X-FDID header on all traffic to c2-redirectors. Bypassing this and hitting the redirector's public IP directly is blocked separately by the redirector's nginx."

  # Default deny (terminal rule at the lowest-priority slot).
  rule {
    action   = "deny(403)"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default deny — fall-through when no allow rule matches."
  }

  # Allow rule — request matches when the X-FDID header equals the
  # per-deploy token. Lower priority number = evaluated first.
  rule {
    action   = "allow"
    priority = "1000"
    match {
      expr {
        expression = "request.headers['x-fdid'].lower() == '${local.fdid_token}'"
      }
    }
    description = "Allow when x-fdid header matches the per-deploy token. Token value is the per-deploy FDID UUID surfaced via outputs.fdid_token (operator wires it into implant config + cover-domain redirector nginx)."
  }
}

# ============================================================================
# DNS — per-redirector A records in the operator's Cloud DNS zone, all
# pointing at the LB's anycast IP. The managed zone lives in the host
# project (different from the per-range project); we use the aliased
# google.dns provider so terraform creates records there.
#
# When advanced_c2.dns_zone_resource_group is empty (operator opted out
# of automated DNS), we skip both the data lookup and the record sets —
# the operator can wire the DNS by hand. The LB + cert still work; the
# cert just won't validate until DNS resolves.
# ============================================================================

data "google_dns_managed_zone" "fronting" {
  provider = google.dns
  count    = local.afd_enabled && var.advanced_c2.dns_zone_resource_group != "" ? 1 : 0
  name     = var.advanced_c2.dns_zone_resource_group
}

resource "google_dns_record_set" "redirector" {
  provider = google.dns
  for_each = (
    local.afd_enabled && var.advanced_c2.dns_zone_resource_group != ""
    ? local.redirectors
    : {}
  )

  name         = "${local.redirector_fqdn[each.key]}."
  managed_zone = data.google_dns_managed_zone.fronting[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.main[0].address]
}
