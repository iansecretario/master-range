# =============================================================================
# Guacamole custom-hostname DNS + cert plumbing
# =============================================================================
# When services.guacamole.dns_zone_name + custom_hostname are set, this
# file:
#   1. Looks up the Azure DNS zone (via the azurerm.guac_dns provider —
#      can be a different subscription than the deployment).
#   2. Creates an A record `<custom_hostname>.<dns_zone_name>` pointing
#      at the Guacamole public IP.
#   3. Surfaces the resulting FQDN as a local that services.tf passes
#      into cloud-init for certbot, and outputs.tf publishes as
#      `guacamole_url`.
#
# When unset, everything in this file no-ops (`count = 0`) and the
# existing Azure-assigned cloudapp.azure.com FQDN remains in use.

# Per-range friendly-phrase + number suffix for the Guacamole public
# hostname. Default pattern is `cwr-guidem-<word>-<3-digit>.<zone>`,
# e.g.   cwr-guidem-falcon-742.cyberwarrange.com
# Friendlier than hex and still gives ~150 words × 1000 numbers =
# 150,000 unique combos — birthday-paradox collision risk at ~450
# concurrent ranges, well above expected fleet size. Both resources
# are keyed to `range_name` so re-applies keep the same FQDN (avoids
# LE's 5-cert-per-domain-per-week rate limit churn).
locals {
  # ~150 short, easy-to-read nouns. Animals, gemstones, weather,
  # weapons-of-the-mythic-variety. Picked to read well in URLs.
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
    var.services.guacamole.custom_hostname != ""
    ? var.services.guacamole.custom_hostname
    : "cwr-guidem-${random_shuffle.guac_hostname_word.result[0]}-${random_integer.guac_hostname_number.result}"
  )

  # Enable the custom-hostname path when the operator has supplied a
  # DNS zone (name + RG). custom_hostname itself defaults to
  # cwr-guidem-<rand>, so we don't gate on it being non-empty.
  guac_custom_enabled = (
    var.services.guacamole.enabled
    && var.services.guacamole.dns_zone_name != ""
    && var.services.guacamole.dns_zone_resource_group != ""
  )

  guac_custom_fqdn = (
    local.guac_custom_enabled
    ? "${local.guac_custom_hostname_resolved}.${var.services.guacamole.dns_zone_name}"
    : ""
  )

  # The FQDN cloud-init feeds to certbot. Prefer the custom hostname
  # when configured; fall back to the Azure-assigned cloudapp one. Note
  # that azurerm_public_ip.guacamole is created with count = enabled?1:0
  # in services.tf, so we have to index [0] and gate on `enabled`.
  guac_effective_fqdn = (
    var.services.guacamole.enabled
    ? (local.guac_custom_enabled
       ? local.guac_custom_fqdn
       : azurerm_public_ip.guacamole[0].fqdn)
    : ""
  )
}

# Data-source the zone via the guac_dns provider alias so we can write
# records into it even when it lives in a separate subscription. We
# only look it up when custom_hostname is enabled; otherwise terraform
# would try to query a non-existent zone with empty strings.
data "azurerm_dns_zone" "guacamole" {
  provider            = azurerm.guac_dns
  count               = local.guac_custom_enabled ? 1 : 0
  name                = var.services.guacamole.dns_zone_name
  resource_group_name = var.services.guacamole.dns_zone_resource_group
}

# Grant the Guacamole VM's system-assigned managed identity write
# access to the cyberwarrange.com DNS zone. certbot-dns-azure uses
# this identity (via Azure IMDS — no SP secrets in cloud-init) to
# write the `_acme-challenge.<zone>` TXT record that LE polls during
# DNS-01 validation. Scope is the zone itself (least privilege —
# can't touch other resources in `aa_group`). Role assignments live
# in the SCOPE's subscription, so this resource uses the
# azurerm.guac_dns provider alias.
#
# DNS Zone Contributor is the canonical role for record CRUD; gives
# write to record-sets but not to the zone metadata itself.
resource "azurerm_role_assignment" "guacamole_dns01" {
  provider             = azurerm.guac_dns
  count                = local.guac_custom_enabled ? 1 : 0
  scope                = data.azurerm_dns_zone.guacamole[0].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_linux_virtual_machine.guacamole[0].identity[0].principal_id
  # NO `lifecycle { ignore_changes = [principal_id] }` here. The previous
  # version had it to suppress azurerm provider over-detection on VM
  # *updates* (where the identity actually doesn't change). But when the
  # VM is *replaced* (e.g. user taints it to rotate userdata), the MSI's
  # principal_id genuinely changes — and ignore_changes silently kept the
  # role assignment pointing at the destroyed VM's defunct identity. The
  # current MSI was then left with zero role assignments, lego saw 403
  # on every DNS-01 write, cert stayed self-signed. Letting terraform
  # detect + replace the assignment costs a few seconds of "no DNS write
  # access" per VM replacement — acceptable trade-off for correctness.
}

# Reader on the zone's resource group. Required because lego's azuredns
# plugin (v4.18+) ALWAYS queries Azure Resource Graph to discover the
# target zone before issuing the DNS-01 challenge — even when
# AZURE_RESOURCE_GROUP + AZURE_ZONE_NAME env vars pin it explicitly.
# Resource Graph returns only resources the caller has Read access to;
# `DNS Zone Contributor` covers `Microsoft.Network/dnsZones/*` actions
# but NOT the general Read needed for the Resource Graph query path,
# so the discover-zones API returns 403 AccessDenied and lego aborts:
#   POST https://management.azure.com/providers/Microsoft.ResourceGraph/resources
#   → RESPONSE 403: Code="AccessDenied"
# Granting Reader at the RG scope is narrower than subscription-wide
# Reader and is exactly the level Resource Graph uses for filtering.
resource "azurerm_role_assignment" "guacamole_dns01_reader" {
  provider             = azurerm.guac_dns
  count                = local.guac_custom_enabled ? 1 : 0
  scope                = "/subscriptions/${var.services.guacamole.dns_zone_subscription_id}/resourceGroups/${var.services.guacamole.dns_zone_resource_group}"
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.guacamole[0].identity[0].principal_id
  # No ignore_changes — see neighbouring guacamole_dns01 for the rationale.
}

# Pin the Guacamole public IP to <custom_hostname>.<dns_zone_name>.
# TTL kept short (5 min) so DNS cache hits don't lag IP changes.
#
# Operator design: the ZONE (cyberwarrange.com) is never managed by
# terraform — it's a `data` lookup. Only the records INSIDE the zone
# (this one A record) are managed; they're destroyed alongside the
# range on `./range destroy`. A different range_name produces a
# different A record name (range-keyed random suffix), so multiple
# ranges sharing the zone don't collide.
#
# Caveat: if the cyberwarrange.com zone has a `CanNotDelete` resource
# lock (Azure auto-applies one when you buy a domain via App Service
# Domains), the lock inherits to child records and blocks deletion on
# destroy. Remove the lock at Portal → DNS Zones → cyberwarrange.com →
# Locks before running `./range destroy`. Lock keeps the zone safe;
# we don't need it on the per-range records.
resource "azurerm_dns_a_record" "guacamole" {
  provider            = azurerm.guac_dns
  count               = local.guac_custom_enabled ? 1 : 0
  name                = local.guac_custom_hostname_resolved
  zone_name           = data.azurerm_dns_zone.guacamole[0].name
  resource_group_name = data.azurerm_dns_zone.guacamole[0].resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.guacamole[0].ip_address]

  tags = {
    range   = var.range_name
    managed = "terra-range"
  }
}
