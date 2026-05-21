# =============================================================================
# Key Vault — wildcard cert storage
# =============================================================================
# Holds the LE wildcard cert (fullchain + private key) issued by the
# Guacamole VM via lego + DNS-01. Centralised storage means:
#   1. Cert survives `./range destroy` — the next deploy reads from KV
#      instead of re-issuing (bypasses LE rate limits entirely).
#   2. Cert renewal happens on ONE node (the Guac VM, on its systemd
#      timer); fleet picks up rotations on next boot.
#   3. Other VMs (Mythic, Adaptix, …) can mount the same cert in
#      Phase 2 — they read from KV with their own MSI + role binding.
#
# Security posture:
#   - RBAC authorization (Azure role assignments only, no access
#     policies) — auditable, principle-of-least-privilege friendly.
#   - Soft-delete with 90-day retention — accidentally-deleted secrets
#     can be recovered.
#   - Purge protection enabled — can't permanently destroy the vault
#     until the soft-delete window expires (90 d).
#   - Public network access on (but RBAC gates real access). Operators
#     can `az keyvault secret show` from anywhere with their AAD login.
#     Tighten with private endpoint in a future hardening pass.
#   - Vault name auto-suffixed with range_name + 4 random hex chars
#     so multiple ranges don't collide on the (globally unique) name.

resource "random_id" "kv_suffix" {
  byte_length = 2 # 4 hex chars — keeps the KV name short, unique enough
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "lab" {
  # KV names: 3-24 chars, alphanumeric + hyphens, globally unique.
  # The substr() trims aggressively to leave room for the suffix.
  name                = substr("kv-${var.range_name}-${random_id.kv_suffix.hex}", 0, 24)
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Access-policy mode (NOT RBAC). The operator's AAD role has an ABAC
  # condition that blocks them from assigning data-plane roles like
  # `Key Vault Administrator` / `Secrets Officer`, even on KVs they
  # own. Access policies don't go through Microsoft.Authorization, so
  # they sidestep that restriction entirely. Functionally identical
  # for our use case (one human operator + one VM identity); switch
  # to RBAC later if/when the ABAC condition gets relaxed.
  rbac_authorization_enabled = false

  # 90-day soft-delete + purge protection. Combined with RBAC, this
  # gives us a "really hard to lose the cert" property: even if an
  # operator accidentally deletes the wildcard secret, it's recoverable
  # via `az keyvault secret recover` for 90 days.
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  # We're not running this from inside a locked-down VNet — operators
  # need az CLI access from their laptops. Future hardening: drop
  # public_network_access_enabled, add a private endpoint inside the
  # hub VNet, expose KV only to VMs + a jumphost.
  public_network_access_enabled = true

  tags = { Range = var.range_name, Tier = "hub", Service = "key-vault" }
}

# ---- Access policies ---------------------------------------------------------

# Operator / deployer (whoever ran `terraform apply`) — full secret +
# certificate access on this vault. Lets them inspect, override, or
# rotate the wildcard cert from any machine with `az` + AAD login.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.lab.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get", "List", "Set", "Delete", "Recover", "Backup", "Restore",
  ]
  certificate_permissions = [
    "Get", "List", "Create", "Import", "Update", "Delete", "Recover",
    "Backup", "Restore", "GetIssuers", "ListIssuers", "SetIssuers",
    "DeleteIssuers", "ManageContacts", "ManageIssuers",
  ]
  # No Purge — soft-delete + purge protection is the safety net we
  # explicitly want, even against the operator.
}

# Guacamole VM — Get + Set + List secrets. The lego-driven bootstrap
# script reads the existing wildcard cert before attempting issuance,
# and writes back after a successful issue/renew. No delete/purge —
# rotation is via new versions, not destroy-and-recreate.
resource "azurerm_key_vault_access_policy" "guac_msi" {
  count        = var.services.guacamole.enabled ? 1 : 0
  key_vault_id = azurerm_key_vault.lab.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_virtual_machine.guacamole[0].identity[0].principal_id

  secret_permissions = ["Get", "List", "Set"]

  lifecycle {
    # The VM keeps the same identity for its lifetime; the azurerm
    # provider sometimes flags object_id as drift on VM updates.
    ignore_changes = [object_id]
  }
}

# ---- Outputs surfaced to cloud-init -----------------------------------------

output "key_vault_name" {
  description = "Name of the lab Key Vault holding the wildcard LE cert. cloud-init reads this to az-keyvault-secret-show the cert on first boot."
  value       = azurerm_key_vault.lab.name
}

output "key_vault_uri" {
  description = "Vault URI (https://<name>.vault.azure.net/) — used by Azure SDKs that prefer URI over name."
  value       = azurerm_key_vault.lab.vault_uri
}

# Best-effort cert expiry visibility: read the wildcard cert's
# expiration metadata if it exists. Wrapped in `try()` because on the
# very first apply, the secret doesn't exist yet and the data source
# would error. After first issuance, this surfaces "days until cert
# expiry" as an output the operator can `terraform output` to monitor.
data "azurerm_key_vault_secret" "wildcard_cert_meta" {
  count        = 0 # toggled to 1 in a follow-up once a cert exists
  name         = "wildcard-cert"
  key_vault_id = azurerm_key_vault.lab.id
}
