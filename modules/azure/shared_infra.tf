################################################################################
# Hub-tier shared infrastructure: Ghostwriter, SteppingStones, RedELK.
#
# These deploy once per range (not per student). Each box gets:
#   - private IP in hub-infra subnet (10.0.1.0/24)
#   - public IP gated to operator CIDRs for the web UI
#   - SSH connection auto-registered in Guacamole under the "shared-infra"
#     connection group
#
# C2 teamservers (Adaptix / Mythic / BRC4) are NOT shared infra — they
# all live in the per-student attacker subnet. RedELK is the only
# logging-sink shared infra; per-student C2 boxes ship their logs to it
# via Filebeat (configured in their userdata).
################################################################################

locals {
  # Pinned hub IP for RedELK so per-student C2 boxes can hard-code it
  # in their Filebeat shipper configs. Logstash listens on :5044.
  redelk_hub_ip = "10.0.1.40"

  redelk_in_yaml = length([
    for s in var.shared_machines : s if s.role == "redelk"
  ]) > 0

  shared_userdata = {
    for s in var.shared_machines :
    s.name => templatefile(
      "${path.module}/userdata/${s.role}.sh",
      {
        linux_user      = s.linux_user
        linux_pass      = s.linux_password
        ssh_pubkey      = local.effective_ssh_pubkey
        elk_endpoint    = "10.0.0.10"
        kibana_password = var.services.elk.kibana_password
      }
    )
  }
}

resource "azurerm_public_ip" "shared" {
  for_each            = { for s in var.shared_machines : s.name => s if s.public_ip }
  name                = "${var.range_name}-${each.key}-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "shared" {
  for_each            = { for s in var.shared_machines : s.name => s }
  name                = "${var.range_name}-${each.key}-nic"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hub_infra.id
    private_ip_address_allocation = each.value.role == "redelk" ? "Static" : "Dynamic"
    private_ip_address            = each.value.role == "redelk" ? local.redelk_hub_ip : null
    public_ip_address_id          = each.value.public_ip ? azurerm_public_ip.shared[each.key].id : null
  }
}

resource "azurerm_linux_virtual_machine" "shared" {
  for_each = { for s in var.shared_machines : s.name => s }

  name                            = "${var.range_name}-${each.key}"
  resource_group_name             = azurerm_resource_group.hub.name
  location                        = azurerm_resource_group.hub.location
  size                            = local.size_map[each.value.size]
  admin_username                  = each.value.linux_user
  admin_password                  = each.value.linux_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.shared[each.key].id]

  priority        = var.vm_priority
  eviction_policy = var.vm_priority == "Spot" ? "Deallocate" : null
  max_bid_price   = var.vm_priority == "Spot" ? -1 : null

  custom_data = base64encode(local.shared_userdata[each.key])

  os_disk {
    name                 = "${var.range_name}-${each.key}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.role == "redelk" ? 200 : 60
  }

  # Prefer pre-baked SIG image (source_image_id) when available; falls
  # back to Marketplace publisher/offer/sku for shared roles that
  # haven't been baked yet. Only ONE of these blocks can be present per
  # VM resource — azurerm validates this at plan time.
  #
  # `local.shared_source_image_id[each.key]` dispatches on s.role —
  # ghostwriter / stepping-stones / redelk each have their own baked
  # image carrying the docker-compose stack + pre-pulled images. Returns
  # null when no baked image applies, in which case the dynamic
  # source_image_reference block below renders Marketplace
  # publisher/offer/sku.
  source_image_id = local.shared_source_image_id[each.key]

  dynamic "source_image_reference" {
    for_each = local.shared_source_image_id[each.key] == null ? [1] : []
    content {
      publisher = local.image_map[each.value.os].publisher
      offer     = local.image_map[each.value.os].offer
      sku       = local.image_map[each.value.os].sku
      version   = local.image_map[each.value.os].version
    }
  }

  tags = {
    Range = var.range_name
    Tier  = "hub"
    Role  = each.value.role
  }

  # Same rationale as the Guacamole / ELK / per-student Linux VMs: a
  # cloud-init userdata rewrite in the module should NOT force-replace a
  # running shared infra box. Replacing one wipes its app state — RedELK
  # loses every Elasticsearch index, SteppingStones drops its sqlite DB
  # (case notes, operator activity, ticket queue). Pick up userdata
  # changes in place via `./range fix <name> --legacy`, which re-runs
  # the current cloud-init through `az run-command` without
  # destroying the disk.
  lifecycle {
    ignore_changes = [custom_data]
  }
}
