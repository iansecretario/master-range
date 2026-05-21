################################################################################
# Guacamole custom-hostname DNS plumbing — GCP port of
# modules/azure/guacamole_dns.tf.
#
# When services.guacamole.dns_zone_name + custom_hostname are set, this
# file:
#   1. Looks up a Cloud DNS managed zone in the operator-supplied
#      project (typically var.gcp_host_project_id — long-lived, shared
#      across ranges — via the google.guac_dns provider alias). The
#      alias is configured in main.tf and can target a different
#      project than the per-range deploy.
#   2. Creates an A record `<custom_hostname>.<dns_zone_name>` pointing
#      at the Guacamole VM's external IP (`google_compute_address.guacamole`
#      in services.tf).
#   3. Surfaces the resulting FQDN as `local.guac_effective_fqdn`, which
#      services.tf passes into cloud-init for certbot, and outputs.tf
#      publishes via `guacamole_url` / `guacamole_fqdn`.
#
# When unset, everything in this file no-ops (`count = 0`) and
# `local.guac_effective_fqdn` resolves to null — outputs.tf falls back
# to the bare public IP literal.
#
# Cert path: SKIPPED here for Phase C. Guacamole's userdata
# (modules/gcp/userdata/guacamole.sh, shared with Azure) already runs
# certbot via HTTP-01 against whatever FQDN cloud-init was rendered
# with. The Google-managed SSL cert path (google_compute_managed_ssl_certificate)
# is reserved for Phase D when cdn.tf wires Guacamole behind a global
# HTTPS load balancer. For now Let's Encrypt is the cert path — same as
# the Azure side's HTTP-01 fallback when DNS-01 isn't configured.
#
# Per-range friendly-phrase + number suffix for the Guacamole hostname,
# mirroring the Azure approach. Default pattern is
# `cwr-guidem-<word>-<3-digit>.<zone>` (e.g.
# cwr-guidem-falcon-742.cyberwarrange.com). Both random resources are
# keyed to `range_name` so re-applies keep the same FQDN (avoids LE's
# 5-cert-per-domain-per-week rate-limit churn).
################################################################################

locals {
  # Word list mirrors modules/azure/guacamole_dns.tf so a range moved
  # between providers can produce the same default subdomain (the
  # range_name → word/number derivation is deterministic).
  guac_hostname_words = [
    "falcon", "phoenix", "raven", "panther", "tiger", "wolf", "hawk",
    "eagle", "shark", "lion", "viper", "kraken", "drake", "cobra",
    "puma", "lynx", "fox", "bear", "elk", "owl", "jackal", "raptor",
    "stallion", "hornet", "stork", "ibis", "moth", "wasp", "ember",
    "frost", "crystal", "obsidian", "azure", "crimson", "violet",
    "indigo", "amber", "cobalt", "jade", "scarlet", "ivory", "onyx",
    "pearl", "ruby", "topaz", "blaze", "spark", "storm", "thunder",
    "tempest", "vortex", "comet", "nova", "nebula", "quasar", "pulsar",
    "stellar", "lunar", "solar", "echo", "ranger", "hunter", "scout",
    "sentry", "guardian", "warden", "knight", "rogue", "ninja",
    "samurai", "spectre", "phantom", "ghost", "wraith", "shade", "myth",
    "saga", "legend", "oracle", "rune", "scribe", "vigil", "watcher",
    "shield", "anchor", "compass", "harbor", "summit", "ridge", "crest",
    "peak", "canyon", "current", "tidal", "kindle", "forge", "iron",
    "steel", "copper", "silver", "gold", "silk", "linen", "cedar",
    "maple", "willow", "spruce", "alder", "birch", "rowan", "oak",
    "stout", "swift", "nimble", "rapid", "quiet", "bold", "valor",
    "honor", "rapids", "rift", "summit", "talon", "fang", "blade",
    "arrow", "lance", "saber", "axe", "hammer", "mantle", "cloak",
    "veil", "halo", "torch", "lantern", "beacon", "signal", "pulse",
    "delta", "sigma", "omega", "alpha", "bravo", "charlie", "echo",
    "foxtrot", "ranger", "ronin", "shogun", "templar", "warden",
  ]
}

resource "random_shuffle" "guac_hostname_word" {
  input        = local.guac_hostname_words
  result_count = 1
  keepers = {
    range_name = var.range_name
  }
}

resource "random_integer" "guac_hostname_number" {
  min = 100
  max = 999
  keepers = {
    range_name = var.range_name
  }
}

locals {
  # Default subdomain when the operator hasn't supplied one explicitly.
  # Per-deploy uniqueness comes from the word + number pair above.
  # Override via services.guacamole.custom_hostname in the scenario
  # YAML or `./range gen <scenario> --guac-subdomain <label>`.
  guac_custom_hostname_resolved = (
    try(var.services.guacamole.custom_hostname, "") != ""
    ? var.services.guacamole.custom_hostname
    : "cwr-guidem-${random_shuffle.guac_hostname_word.result[0]}-${random_integer.guac_hostname_number.result}"
  )

  # Enable the custom-hostname path when the operator has supplied a
  # DNS zone. Unlike the Azure side (which also needs a resource group),
  # GCP Cloud DNS zones are project-scoped — the project is picked by
  # the google.guac_dns provider alias (configured in main.tf to use
  # services.guacamole.dns_zone_subscription_id when set, else
  # var.gcp_host_project_id, else the per-range project).
  guac_custom_enabled = (
    var.services.guacamole.enabled
    && try(var.services.guacamole.dns_zone_name, "") != ""
  )

  guac_custom_fqdn = (
    local.guac_custom_enabled
    ? "${local.guac_custom_hostname_resolved}.${var.services.guacamole.dns_zone_name}"
    : ""
  )

  # The FQDN cloud-init feeds to certbot. Prefer the custom hostname
  # when configured; fall back to null so outputs.tf falls back to the
  # bare public IP literal. Mirrors the Azure module's
  # `local.guac_effective_fqdn` but without the cloudapp.azure.com leg
  # (GCP has no equivalent free auto-FQDN on a reserved external IP).
  #
  # CONTRACT: outputs.tf references this local with try() and treats a
  # null value as "no custom hostname — use the IP literal". Don't
  # change the TYPE from string-or-null.
  guac_effective_fqdn = (
    var.services.guacamole.enabled && local.guac_custom_enabled
    ? local.guac_custom_fqdn
    : null
  )
}

################################################################################
# Cloud DNS zone lookup. The zone lives in the operator's long-lived
# host project (var.gcp_host_project_id) by default; per-scenario
# override via services.guacamole.dns_zone_subscription_id.
#
# The google.guac_dns provider alias (declared in main.tf) already
# resolves the right project — we just pass the zone NAME here.
#
# A note on `dns_zone_subscription_id`: the field name is carried over
# verbatim from the Azure module for cross-provider symmetry. On GCP it
# holds a project ID, not a subscription ID. The terraform field is
# typed `string` either way; the only thing it does is feed
# main.tf's provider alias resolution.
################################################################################

data "google_dns_managed_zone" "guac" {
  provider = google.guac_dns
  count    = local.guac_custom_enabled ? 1 : 0
  name     = var.services.guacamole.dns_zone_name
  project = (
    try(var.services.guacamole.dns_zone_subscription_id, "") != ""
    ? var.services.guacamole.dns_zone_subscription_id
    : (var.gcp_host_project_id != "" ? var.gcp_host_project_id : var.gcp_project_id)
  )
}

################################################################################
# A record `<custom_hostname>.<dns_zone_name>` pointing at the
# Guacamole VM's external IP.
#
# Operator design: the ZONE is never managed by terraform — it's a
# `data` lookup. Only the records INSIDE the zone (this one A record)
# are managed; they're destroyed alongside the range on
# `./range destroy`. A different range_name produces a different A
# record name (range-keyed random suffix), so multiple ranges sharing
# the zone don't collide.
#
# TTL kept short (5 min) so DNS cache hits don't lag IP changes when
# the Guacamole VM is replaced.
################################################################################

resource "google_dns_record_set" "guac" {
  provider     = google.guac_dns
  count        = local.guac_custom_enabled ? 1 : 0
  managed_zone = data.google_dns_managed_zone.guac[0].name
  # Cloud DNS rrset names are fully-qualified with a trailing dot.
  name = "${local.guac_custom_hostname_resolved}.${var.services.guacamole.dns_zone_name}."
  type = "A"
  ttl  = 300
  # google_compute_address.guacamole[0] is declared in services.tf with
  # count = var.services.guacamole.enabled ? 1 : 0. We're already gated
  # on guac.enabled via local.guac_custom_enabled above, so the [0]
  # index is always populated here.
  rrdatas = [google_compute_address.guacamole[0].address]
  project = data.google_dns_managed_zone.guac[0].project
}

################################################################################
# Cert path — PHASE C SKIP. Guacamole's userdata runs certbot/Let's
# Encrypt via the HTTP-01 challenge on :80 against guac_fqdn (set above).
# firewall.tf already opens :80 from 0.0.0.0/0 to the `guacamole` tag
# specifically for this. No Google-managed SSL cert is needed at this
# layer because the VM serves TLS directly (nginx in the docker-compose
# stack); managed certs only matter when fronting via a GCLB.
#
# Phase D (cdn.tf wiring Guacamole behind a Global External HTTPS LB)
# will add a `google_compute_managed_ssl_certificate` for guac_fqdn and
# route :443 through the LB instead. At that point this file will get
# a sibling resource block; nothing else here needs to change.
################################################################################
