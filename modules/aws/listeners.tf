################################################################################
# Per-C2-stack listener-config builders. Mirror of modules/azure/listeners.tf.
#
# Differences for AWS:
#   - The CDN of record is CloudFront; the "azure" CDN key is kept in the
#     map shape (so register.py + cdn_headers downstream consumers stay
#     identical), but its callback URL points to the CloudFront alias
#     domain (Authrix.com) instead of an AFD endpoint.
#   - When advanced_c2.enabled is false, callback hosts fall back to
#     CHANGEME placeholders (same behavior as Azure). cloudfront.tf
#     wires real values in when advanced_c2 is on.
################################################################################

locals {
  # Browser-ish User-Agent for HTTP beacons.
  beacon_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  # (student_id, fronted-role) → redirector machine name.
  redirector_for = {
    for m in var.machines :
    "${m.student_id}-${m.fronts}" => m.name
    if m.role == "c2-redirector" && m.fronts != ""
  }

  # Subdomain per redirector — for AWS that's the CloudFront alias label.
  # When advanced_c2 is off, this is empty and the c2_server / c2_brc4
  # userdata renders CHANGEME-* placeholders that the operator can edit
  # post-deploy.
  cf_enabled = var.advanced_c2.enabled && var.advanced_c2.domain != ""
  redirector_subdomain = local.cf_enabled ? {
    for idx, m in [
      for m in var.machines : m if m.role == "c2-redirector" && m.fronts != ""
    ] :
    m.name => (
      m.callsign != ""
      ? m.callsign
      : "redir-${m.student_id}-${replace(m.fronts, "c2-", "")}"
    )
  } : {}

  # AWS analog of `azure_callback_for` — keyed by fronted-role + student.
  # In CloudFront-mode the "azure" slot points at the CF alias domain.
  # All other CDN slots (cloudfront/workers/fastly/other) remain CHANGEME
  # for the MVP — multi-CDN fronting is a Tier-2 enhancement.
  cloudfront_callback_for = {
    for stack_role in ["c2-server", "c2-mythic", "c2-brc4"] :
    stack_role => {
      for sid in local.students :
      sid => (
        local.cf_enabled && contains(keys(local.redirector_for), "${sid}-${stack_role}")
        ? "${local.redirector_subdomain[local.redirector_for["${sid}-${stack_role}"]]}.${var.advanced_c2.domain}"
        : "CHANGEME-azure-${sid}"
      )
    }
  }
}

# ---- Adaptix listener configs ----------------------------------------------
locals {
  adaptix_listeners = {
    for sid in local.students :
    sid => [
      for cdn in local.cdn_names : {
        name = "${cdn}_HTTPS"
        config = {
          host_bind = "0.0.0.0"
          port_bind = local.cdn_port[cdn]
          callback_addresses = [
            cdn == "azure"
            ? "${local.cloudfront_callback_for["c2-server"][sid]}:443"
            : "CHANGEME-${cdn}-${sid}:443"
          ]
          encrypt_key      = local.adaptix_listener_enc_keys[sid][cdn]
          http_method      = "POST"
          uri              = "/endpoint"
          hb_header        = "X-Forwarded-For"
          user_agent       = local.beacon_user_agent
          host_header      = ""
          request_headers  = {}
          response_headers = {}
          ssl              = true
          ssl_cert         = "/opt/adaptix/server.rsa.crt"
          ssl_key          = "/opt/adaptix/server.rsa.key"
          "page-payload"   = "<<<PAYLOAD_DATA>>>"
          "page-error"     = "<!doctype html><title>404</title><h1>Not Found</h1>"
        }
      }
    ]
  }
}

# ---- BRC4 c2.profile (per-student) -----------------------------------------
# Minimal version of Azure's brc4_profile — same JSON shape so the
# c2-brc4 userdata renders without error. CHANGEME placeholders for
# non-CloudFront CDNs until multi-CDN fronting is wired.
locals {
  brc4_callback_host = {
    for sid in local.students :
    sid => {
      azure      = local.cloudfront_callback_for["c2-brc4"][sid]
      cloudfront = "CHANGEME-cloudfront-${sid}"
      workers    = "CHANGEME-workers-${sid}"
      fastly     = "CHANGEME-fastly-${sid}"
      other      = "CHANGEME-other-${sid}"
    }
  }

  brc4_listener_block = {
    for sid in local.students :
    sid => {
      for cdn in local.cdn_names :
      "${cdn}_HTTPS" => {
        safe_memory     = true
        append          = "\"}"
        auth_count      = 1
        auth_type       = false
        c2_authkeys     = [local.cdn_headers["brc4"][sid][cdn].value]
        c2_uri          = ["/endpoint"]
        respawn         = true
        die_offline     = false
        request_headers = { "Cache-Control" = "no-cache", "Pragma" = "no-cache" }
        response_headers = {}
        exec_method     = "Thread-0"
        host            = local.brc4_callback_host[sid][cdn]
        is_random       = false
        port            = tostring(local.cdn_port[cdn])
        prepend         = "{\"channel\":\""
        useragent       = local.beacon_user_agent
        ssl_method      = "SSLv23"
        verify_peer     = false
      }
    }
  }

  brc4_profile = {
    for sid in local.students :
    sid => jsonencode({
      "listener" = local.brc4_listener_block[sid]
    })
  }
}
