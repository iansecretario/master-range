# Provider-port note: this file was copied verbatim from
# modules/azure/listeners.tf and renamed `azure_callback_for` →
# `gcp_callback_for`. The contents are pure data transforms over
# var.machines + per-stack passwords — no provider-specific
# resources here, so the port is structural only. Future divergence
# (e.g., Cloud CDN-specific callback shape) can be added below.
#
################################################################################
# Per-C2-stack listener-config builders.
#
# All three C2 frameworks pre-create the same five HTTPS listeners on
# ports 8443–8447. Per-student. The shape of "listener config" differs
# per framework so we build three parallel blobs here and thread them
# into vms.tf via templatefile() variables.
#
#   Adaptix → JSON list of {name, config} entries; the per-VM helper
#             POSTs each to /listener/create.
#   Mythic  → static config.json on disk; ports/SSL are uniform across
#             students. Nothing to compute here.
#   BRC4    → full c2.profile JSON dropped at boot.
#
# BRC4 license caps the range at one teamserver, so c2-brc4 scenarios
# always have students.count: 1 — the per-student maps below collapse
# to a single entry but keep the same shape as Adaptix/Mythic.
################################################################################

# ---- Common per-CDN data ----------------------------------------------------

locals {
  # Beacon User-Agent (plausible Chrome on Windows).
  beacon_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  # (student_id, fronted-role) → redirector machine name.
  redirector_for = {
    for m in var.machines :
    "${m.student_id}-${m.fronts}" => m.name
    if m.role == "c2-redirector" && m.fronts != ""
  }

  # Cloud CDN FQDN per (student, fronted-role). When Cloud CDN is enabled and the
  # student template includes a redirector for this stack, this resolves
  # to <subdomain>.<domain>. Otherwise a placeholder the operator
  # updates by hand or by editing the listener after deploy.
  gcp_callback_for = {
    for stack_role in ["c2-server", "c2-mythic", "c2-brc4"] :
    stack_role => {
      for sid in local.students :
      sid => (
        var.advanced_c2.enabled && contains(keys(local.redirector_for), "${sid}-${stack_role}")
        # Cloud CDN path (operator-side / advanced_c2 enabled): use the
        # per-redirector Cloud CDN endpoint's *.azurefd.net hostname so beacon
        # configs don't leak the operator's custom-domain DNS zone.
        ? "CHANGEME-cdn-${sid}-${stack_role}.cdn.example" # populated by cdn.tf when advanced_c2 is enabled (Phase D)
        # Local-IP fallback (student-redteam-lab and any deploy with
        # advanced_c2 disabled): resolve to the per-student teamserver's
        # private IP directly. Beacons stay inside the VNet, no Cloud CDN edge
        # hop, no DNS resolution required. The teamserver of role=stack_role
        # belonging to student=sid is found by scanning var.machines for
        # the matching (role, student_id) pair; effective_static_ip gives
        # us its IP (e.g. "10.1.1.5" for c2-server in student lab01's
        # spoke). try() falls back to the legacy CHANGEME placeholder if
        # no matching machine exists in var.machines — the operator can
        # still edit the listener post-deploy.
        : try(
          [
            for m in var.machines :
            local.effective_static_ip[m.name]
            if m.role == stack_role && m.student_id == sid && local.effective_static_ip[m.name] != ""
          ][0],
          "CHANGEME-azure-${sid}"
        )
      )
    }
  }
}

# ---- Adaptix listener configs ----------------------------------------------
#
# Five BeaconHTTP listeners per student (one per CDN, ports 8443-8447)
# + four singleton extra-protocol listeners per student:
#   * dns_BeaconDNS    (port 53, external — DNS/DoH tunneling)
#   * smb_BeaconSMB    (internal, named pipe — no teamserver port bound)
#   * tcp_BeaconTCP    (internal — agent binds 4444 on target; teamserver
#                       doesn't bind this port, the value is metadata
#                       baked into the badger for peer connect-back)
#   * gopher_GopherTCP (port 8448, external — gopher agent's TCP/mTLS
#                       channel; needed for the adaptix_payload role's
#                       gopher build matrix entry to find a compatible
#                       listener and stop being skipped)
#
# Each entry has shape {name, type, config}. `type` is consumed by
# configure_listeners.py (c2-server.sh) and POSTed verbatim as the
# `type` field of /listener/create — see Adaptix's docs for the full
# enum (BeaconHTTP / BeaconDNS / BeaconSMB / BeaconTCP / GopherTCP).
# Names use a `<flavor>_<type-tag>` convention so the suffix half is a
# fallback signal for adaptix_payload's name-heuristic listener-kind
# detector when the /listener/list API somehow drops `l_reg_name`.

locals {
  # 5 BeaconHTTP listeners (one per CDN) — the existing per-CDN-fronted
  # set. These are external; ports 8443-8447 are NSG-open from the
  # adaptix redirector (.6) only.
  adaptix_http_listeners = {
    for sid in local.students :
    sid => [
      for cdn in local.cdn_names : {
        name = "${cdn}_HTTPS"
        type = "BeaconHTTP"
        config = {
          host_bind = "0.0.0.0"
          port_bind = local.cdn_port[cdn]
          # IMPORTANT: AdaptixServer's BeaconHTTP listener parses each
          # callback_addresses entry with `net.SplitHostPort` — a full
          # URL ("https://host:443/") yields "Invalid address (cannot
          # split host:port)" and the cloud-init configure_listeners.py
          # oneshot fails for all 5 listeners. Emit bare host:port. SSL
          # framing comes from the listener's own `ssl: true` flag below.
          callback_addresses = [
            cdn == "azure"
            ? "${local.gcp_callback_for["c2-server"][sid]}:443"
            : "CHANGEME-${cdn}-${sid}:443"
          ]
          encrypt_key = local.adaptix_listener_enc_keys[sid][cdn]
          http_method = "POST"
          # Beacon callback URI — kept realistic-looking ("/api/auth/token")
          # rather than an obvious "/endpoint", so the lab's C2 traffic
          # blends into normal-looking API requests for the blue-team
          # detection exercise. Cloud CDN routes /* and the c2-redirector is a
          # catch-all passthrough, so any path works end-to-end — this is
          # purely about the URI looking plausible. NOTE: distinct from
          # the Adaptix Teamserver *commander* endpoint (c2-server.sh
          # `endpoint: "/endpoint"`) which is operator access, not beacon
          # traffic, and intentionally stays as-is.
          uri              = "/api/auth/token"
          hb_header        = "X-Forwarded-For"
          user_agent       = local.beacon_user_agent
          host_header      = ""
          request_headers  = {}
          response_headers = {}
          ssl              = true
          ssl_cert         = "/opt/adaptix/server.rsa.crt"
          ssl_key          = "/opt/adaptix/server.rsa.key"
          # page-payload must contain the placeholder per validConfig().
          "page-payload" = "<<<PAYLOAD_DATA>>>"
          "page-error"   = "<!doctype html><title>404</title><h1>Not Found</h1>"
        }
      }
    ]
  }

  # Per-student singletons for the four extra listener kinds. NOT
  # per-CDN — they are not fronted through CDNs (DNS uses raw UDP/53
  # or DoH; SMB/TCP are internal pivots; GopherTCP is a raw TCP/mTLS
  # listener directly accessed via the redirector). Running 5×4 = 20
  # additional listeners per student would be overkill for a teaching
  # lab; one of each kind is enough to demonstrate the channel.
  #
  # All four reuse the per-student `azure` 32-hex RC4 key. This is
  # safe because each listener still has its own `name` namespace on
  # the teamserver — the key is only used to encrypt beacon traffic
  # to/from THIS listener, not as a global cross-listener secret.
  adaptix_extra_listeners = {
    for sid in local.students :
    sid => [
      {
        name = "dns_BeaconDNS"
        type = "BeaconDNS"
        config = {
          host_bind = "0.0.0.0"
          port_bind = 53
          # `domain` is the suffix the agent appends to each query so
          # the listener can identify and parse C2 traffic. The label
          # tree is local-only — the lab range doesn't own a real
          # public domain, but the listener will accept any query
          # whose trailing labels match this string. Operator can
          # change this after-deploy via Edit Listener.
          domain        = "adaptix-${sid}.local"
          pkt_size      = 240
          ttl           = 10
          encrypt_key   = local.adaptix_listener_enc_keys[sid]["azure"]
          burst_enabled = false
          burst_sleep   = 50
          burst_jitter  = 0
        }
      },
      {
        name = "smb_BeaconSMB"
        type = "BeaconSMB"
        config = {
          # Pipe name only — the server prepends `\\.\pipe\` before
          # surfacing it in /listener/list. Must match the extender's
          # `[a-zA-Z0-9._-]+` regex (so per-student `-` is fine).
          pipename    = "adaptix-${sid}"
          encrypt_key = local.adaptix_listener_enc_keys[sid]["azure"]
        }
      },
      {
        name = "tcp_BeaconTCP"
        type = "BeaconTCP"
        config = {
          # Teamserver does NOT actually bind this port — BeaconTCP is
          # an INTERNAL listener; the port is metadata baked into the
          # badger so peer-pivot agents know where to connect on the
          # target host. So no NSG change needed for this listener.
          port_bind    = 4444
          prepend_data = ""
          encrypt_key  = local.adaptix_listener_enc_keys[sid]["azure"]
        }
      },
      {
        name = "gopher_GopherTCP"
        type = "GopherTCP"
        config = {
          host_bind = "0.0.0.0"
          port_bind = 8448
          # Same Cloud CDN callback as the BeaconHTTP `azure` listener but
          # different port. Operator updates by hand if they want a
          # CDN-fronted callback for this listener. Newline-separated
          # per the gopher listener extender's `strings.Split(..., "\n")`.
          callback_addresses = "${local.gcp_callback_for["c2-server"][sid]}:8448"
          encrypt_key        = local.adaptix_listener_enc_keys[sid]["azure"]
          # Plain TCP for v1. Flip ssl=true + provide ca_cert/server_cert/
          # server_key/client_cert/client_key bytes to switch to mTLS.
          ssl          = false
          tcp_banner   = ""
          error_answer = "<!doctype html><title>404</title><h1>Not Found</h1>"
          timeout      = 30
        }
      },
      # Second GopherTCP listener on port 8449 — alternate / failover
      # transport. Distinct name prefix `alt_` so the adaptix_payload
      # role's via prefix-matcher picks it up via the `alt` entry in
      # adaptix_payload_listener_vias. The teamserver supports multiple
      # gopher listeners; this gives the operator a redundant TCP path
      # without needing to bring mTLS cert plumbing online.
      {
        name = "alt_GopherTCP"
        type = "GopherTCP"
        config = {
          host_bind          = "0.0.0.0"
          port_bind          = 8449
          callback_addresses = "${local.gcp_callback_for["c2-server"][sid]}:8449"
          encrypt_key        = local.adaptix_listener_enc_keys[sid]["azure"]
          ssl                = false
          tcp_banner         = ""
          error_answer       = "<!doctype html><title>404</title><h1>Not Found</h1>"
          timeout            = 30
        }
      },
    ]
  }

  # Merged per-student listener list. configure_listeners.py iterates
  # this and POSTs each entry to /listener/create as
  # {name, type, config:json.dumps(config)}.
  adaptix_listeners = {
    for sid in local.students :
    sid => concat(local.adaptix_http_listeners[sid], local.adaptix_extra_listeners[sid])
  }
}

# ---- BRC4 c2.profile builder (per-student; license caps to count=1) -------

locals {
  # Per-student callback host. Azure resolves to AFD; non-Azure CDNs
  # default to placeholders the operator fills in post-deploy.
  brc4_callback_host = {
    for sid in local.students :
    sid => {
      azure      = local.gcp_callback_for["c2-brc4"][sid]
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
        safe_memory = true
        append      = "\"}"
        auth_count  = 1
        auth_type   = false
        c2_authkeys = [local.cdn_headers["brc4"][sid][cdn].value]
        c2_uri      = ["/api/auth/session", "/api/auth/token"]
        respawn     = true
        die_offline = false
        request_headers = {
          "Cache-Control" = "no-cache"
          "Pragma"        = "no-cache"
        }
        response_headers       = {}
        exec_method            = "Thread-0"
        host                   = local.brc4_callback_host[sid][cdn]
        is_random              = false
        port                   = tostring(local.cdn_port[cdn])
        prepend                = "{\"channel\":\""
        rotational_host        = local.brc4_callback_host[sid][cdn]
        ssl                    = true
        disable_http_telemetry = true
        useragent              = local.beacon_user_agent
        sleep                  = 60
        jitter                 = 40
        key_strategy_type      = "default"
        delay_exec             = 0
        stack_link_method      = "stack_pivot"
        stomp                  = "d2d1.dll"
        proxy                  = ""
        proxy_user             = ""
        proxy_pass             = ""
        obfsleep               = "APC"
        data_encoding          = "Base64"
        prepend_response       = "{\"output\":\""
        empty_response         = "{\"info\":\"ok\"}"
        append_response        = "\"}"
        safe_http              = true
      }
    }
  }

  brc4_payload_block = {
    for sid in local.students :
    sid => {
      for cdn in local.cdn_names :
      "${cdn}_HTTPS" => {
        safe_memory     = true
        append          = "\"}"
        append_response = "\"}"
        c2_auth         = local.cdn_headers["brc4"][sid][cdn].value
        c2_uri          = ["/api/auth/session", "/api/auth/token"]
        die_offline     = true
        respawn         = true
        request_headers = {
          "Cache-Control" = "no-cache"
          "Pragma"        = "no-cache"
        }
        exec_method            = "Thread-0"
        host                   = local.brc4_callback_host[sid][cdn]
        jitter                 = 40
        obfsleep               = "APC"
        data_encoding          = "Base64"
        port                   = tostring(local.cdn_port[cdn])
        prepend                = "{\"channel\":\""
        prepend_response       = "{\"output\":\""
        sleep                  = 60
        delay_exec             = 0
        ssl                    = true
        key_strategy_type      = "default"
        stack_link_method      = "stack_pivot"
        disable_http_telemetry = true
        type                   = "HTTP"
        useragent              = local.beacon_user_agent
      }
    }
  }

  brc4_profile = {
    for sid in local.students :
    sid => jsonencode({
      admin_list        = { admin = local.effective_brc4_password[sid] }
      file_upload_chunk = 4194304
      # c2_handler binds the BRC4 commander/API endpoint. Must be 0.0.0.0
      # (not 127.0.0.1) for Kali to reach :9000 — BRC4's REST/WS API and
      # the Commander GUI both connect to this port. NSG already locks
      # external access to the Kali subnet (see c2-brc4.sh ":9000 commander/
      # operator port (Kali-only via NSG)"), so 0.0.0.0 is safe.
      c2_handler = "0.0.0.0:9000"
      # Second operator account used by the brc4_payload Ansible role to
      # drive the API. Distinct identity from `admin` so the operator's
      # Commander GUI session and the playbook's API session run
      # concurrently as independent sessions on the same :9000 port
      # (BRC4 issues a fresh token per /login; re-logging the same
      # operator can invalidate the prior token — use a dedicated user
      # for automation to avoid kicking the GUI).
      user_list   = { automation = local.effective_brc4_automation_password[sid] }
      badgers     = {}
      credentials = []
      autoruns    = []
      click_script = {
        Discovery = ["ipstats", "pwd", "lsdr", "net users"]
      }
      listeners      = local.brc4_listener_block[sid]
      payload_config = local.brc4_payload_block[sid]
      comm_enc_key   = local.adaptix_listener_enc_keys[sid]["azure"] # any 32-hex value
      ssl_cert       = "cert.pem"
      ssl_key        = "key.pem"
      auto_save      = true
      psexec_config = {
        psexec_svc_desc = "Manages universal application core process that in Windows 8 and continues in Windows 10."
        psexec_svc_name = "TransactionBrokerService"
      }
    })
  }
}
