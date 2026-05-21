################################################################################
# Shared Guacamole — standalone, persistent, decoupled from any range.
################################################################################
# This module deploys ONE Guacamole VM that survives every `./range destroy`.
# Range applies register their connections into this Guac via the REST API
# (Phase 2B work — register.py refactor for multi-range namespaced
# registration); range destroys de-register without touching the Guac VM
# itself.
#
# Architecturally:
#   envs/shared-guac-azure/         ← own terraform state (persistent)
#   ↓ calls
#   modules/shared-guac/            ← THIS file
#   ↓ creates
#   shared-guac-rg                  ← own resource group
#     ├── shared-guac-vnet (10.250.0.0/22)
#     ├── shared-guac-mgmt subnet (10.250.0.0/24)
#     ├── public IP (static)
#     ├── DNS A record (guac.cyberwarrange.com if dns_zone_name set)
#     └── Guacamole VM (B4ms, persistent)
#
# Each range deploy adds a VNet PEERING between its hub VNet and this
# Guac's VNet (Phase 2B — added per-range on apply, removed on destroy)
# so Guac can reach the range's spoke private IPs.
#
# This Phase 2A module: builds the VM + infra. Multi-tenant peering +
# register.py per-range registration is Phase 2B.
################################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "~> 4.0"
      configuration_aliases = [azurerm.dns]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Used by outputs.tf to expose the subscription id range applies will need
# for cross-sub peering.
data "azurerm_subscription" "current" {}

# ---- Random password for the Guac admin when admin_password is empty ----
resource "random_password" "admin" {
  length      = 28
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 1
  # JSON-safe + shell-safe — no backslash, single-quote, or double-quote.
  override_special = "!@#%^&*-_+="
}

locals {
  effective_admin_password = (
    var.admin_password != "" ? var.admin_password : random_password.admin.result
  )
  use_custom_dns = (
    var.dns_zone_name != "" && var.dns_zone_resource_group != "" && var.custom_hostname != ""
  )
  # The hostname the operator will use to reach the Guac UI. Either the
  # custom domain (guac.cyberwarrange.com) or the Azure-assigned
  # cloudapp.azure.com FQDN if no custom DNS is configured.
  effective_fqdn = (
    local.use_custom_dns
    ? "${var.custom_hostname}.${var.dns_zone_name}"
    : azurerm_public_ip.guac.fqdn
  )
}

# ---- Random suffix for the cloudapp.azure.com label (no-custom-DNS path)
resource "random_string" "dns_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---- Resource group ------------------------------------------------------
resource "azurerm_resource_group" "guac" {
  name     = "${var.name}-rg"
  location = var.azure_region
  tags     = var.tags

  # Persistent across range destroys. Operator can still tear down the
  # shared Guac explicitly via `./range guac destroy` — which removes
  # this RG via terraform destroy. prevent_destroy doesn't make sense at
  # the env-dir level (the whole env IS the lifecycle); the protection
  # is that this RG isn't in any per-range terraform state.
}

# ---- Network -------------------------------------------------------------
resource "azurerm_virtual_network" "guac" {
  name                = "${var.name}-vnet"
  resource_group_name = azurerm_resource_group.guac.name
  location            = azurerm_resource_group.guac.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "mgmt" {
  name                 = "mgmt"
  resource_group_name  = azurerm_resource_group.guac.name
  virtual_network_name = azurerm_virtual_network.guac.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "mgmt" {
  name                = "${var.name}-mgmt-nsg"
  resource_group_name = azurerm_resource_group.guac.name
  location            = azurerm_resource_group.guac.location
  tags                = var.tags

  # SSH for operator admin (from ingress CIDRs only). Chunked to support
  # the geofence sized lists. Same pattern as modules/azure/hub.tf.
  dynamic "security_rule" {
    for_each = chunklist(var.ingress_cidrs, 3500)
    content {
      name                       = "operator-ssh-${security_rule.key}"
      priority                   = 100 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  # HTTPS — operator + students reach Guac via 443. nginx (in the Guac VM)
  # terminates TLS + reverse-proxies to the guacamole container on
  # localhost:8080.
  dynamic "security_rule" {
    for_each = chunklist(var.ingress_cidrs, 3500)
    content {
      name                       = "guac-https-${security_rule.key}"
      priority                   = 200 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  # HTTP — needed for Let's Encrypt's HTTP-01 challenge. Allow from
  # anywhere (LE's validation servers don't have a fixed CIDR), then
  # the LE bootstrap script flips this to deny after issuing.
  security_rule {
    name                       = "le-http-01"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow inbound from peered range VNets (10.0.0.0/8) so when a range
  # peers to this Guac VNet, range-side hosts can reach guacd's
  # back-channel (this is mostly belt-and-braces — Guac initiates
  # connections OUT to range hosts, not the other way around).
  security_rule {
    name                       = "from-range-vnets"
    priority                   = 400
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

  # Deny everything else inbound.
  security_rule {
    name                       = "deny-all-in"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Outbound is unrestricted — Guac initiates RDP/SSH to range hosts in
  # peered VNets, calls out to Let's Encrypt for cert renewal, pulls
  # Docker images on boot, etc.
  security_rule {
    name                       = "egress-all"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id                 = azurerm_subnet.mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

# ---- Public IP + DNS -----------------------------------------------------
resource "azurerm_public_ip" "guac" {
  name                = "${var.name}-pip"
  resource_group_name = azurerm_resource_group.guac.name
  location            = azurerm_resource_group.guac.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  # Only ask for the Azure cloudapp.azure.com hostname when there's no
  # custom DNS — same logic as the per-range Guac in services.tf.
  domain_name_label = local.use_custom_dns ? null : "${var.name}-${random_string.dns_suffix.result}"
}

# DNS A record (when custom DNS configured) lives in the DNS zone's RG /
# subscription. The provider alias `azurerm.dns` is declared in
# required_providers above (configuration_aliases) — the env dir
# (envs/shared-guac-azure/main.tf) supplies the actual provider config,
# pointed at the DNS zone's subscription if it differs from the deploy
# subscription.
resource "azurerm_dns_a_record" "guac" {
  count               = local.use_custom_dns ? 1 : 0
  provider            = azurerm.dns
  name                = var.custom_hostname
  zone_name           = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 300
  records             = [azurerm_public_ip.guac.ip_address]
  tags                = var.tags
}

# ---- NIC + VM ------------------------------------------------------------
resource "azurerm_network_interface" "guac" {
  name                = "${var.name}-nic"
  resource_group_name = azurerm_resource_group.guac.name
  location            = azurerm_resource_group.guac.location
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.static_ip
    public_ip_address_id          = azurerm_public_ip.guac.id
  }
}

resource "azurerm_linux_virtual_machine" "guac" {
  name                            = "${var.name}-vm"
  resource_group_name             = azurerm_resource_group.guac.name
  location                        = azurerm_resource_group.guac.location
  size                            = var.vm_size
  admin_username                  = var.admin_user
  admin_password                  = local.effective_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.guac.id]
  tags                            = var.tags

  # NEVER use Spot for the shared Guac. Eviction would drop EVERY
  # operator + student session at once and require a manual restart +
  # cache warmup. Pay PAYG; with `./range guac pause` overnight + Spot
  # not being a real saving on the Guac line item, the math doesn't
  # support Spot here.
  priority        = "Regular"
  eviction_policy = null

  # Reuse the per-range Guac's userdata. It's idempotent on first boot:
  # writes the empty manifest, starts the Docker stack (Postgres +
  # guacd + guacamole), runs register.py which finds nothing to
  # register and exits cleanly. Range applies later POST to /api/...
  # to add their connections; nothing in the Phase 2A flow requires a
  # pre-populated manifest.
  #
  # Variables that come from the per-range userdata's optional features
  # (wildcard cert via Key Vault, SSH key from the operator) are set to
  # empty strings here — the userdata's bootstrap script does feature
  # detection (`[[ -n "$guac_wildcard_zone" ]]`) and falls back to the
  # simpler HTTP-01 / no-KV / password-auth path. That's exactly what we
  # want for the shared Guac MVP: HTTP-01 cert for guac.cyberwarrange.com,
  # admin_password (random or operator-supplied) for SSH access if needed.
  custom_data = base64encode(templatefile("${path.module}/../azure/userdata/guacamole.sh", {
    admin_user      = var.admin_user
    admin_password  = local.effective_admin_password
    manifest_b64    = base64encode(jsonencode({
      "admin" : {
        "username" : var.admin_user,
        "password" : local.effective_admin_password,
      },
      "autoregister" : true,
      "connections" : [],
      "students" : [],
    }))
    guac_fqdn       = local.effective_fqdn
    guac_acme_email = var.acme_email

    # Optional features OFF for the shared Guac MVP. Wildcard cert via
    # KV is overkill when the shared Guac only owns ONE hostname
    # (guac.<zone>); HTTP-01 against that hostname is simpler + already
    # works in the per-range Guac path. Operator can flip these on
    # later by populating the Key Vault + DNS zone fields and adding
    # KV permissions to the Guac VM's managed identity.
    guac_wildcard_zone     = ""
    guac_wildcard_zone_rg  = ""
    guac_wildcard_zone_sub = ""
    guac_kv_name           = ""

    # SSH pubkey planting OFF for the shared Guac MVP. Operator falls
    # back to admin_password if they need to SSH (rare — most Guac
    # admin happens via the web UI). Phase 2B can plumb the operator's
    # key through if SSH access becomes a routine workflow.
    ssh_pubkey = ""
  }))

  os_disk {
    name                 = "${var.name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    # 128 GB for postgres growth + Docker image cache + logs over time.
    # The per-range Guac uses 64 GB; we double it for the shared one
    # because it holds N cohorts' worth of connection records.
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
