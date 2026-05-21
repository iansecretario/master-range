################################################################################
# Hub: one resource group with the shared services that every student uses.
# Guacamole + ELK live here. Students get their own RGs and VNets that peer
# back to the hub.
################################################################################

locals {
  # Defense-in-depth NSG cap. Azure NSG hard limit is 6000 source
  # prefixes summed across ALL rules in the NSG. The hub_mgmt NSG fans
  # the same CIDR list across 3 service rules (https/ssh/kibana), so
  # each must stay <= 1900 to keep total < 6000 with safety margin.
  # Generator caps at 1800; this slice() keeps things sane even when
  # an operator hand-runs `terraform apply` against stale tfvars.
  _nsg_cidr_cap = 1900
  effective_ingress_cidrs = slice(
    var.guacamole_ingress_cidrs,
    0,
    min(local._nsg_cidr_cap, length(var.guacamole_ingress_cidrs))
  )
}

resource "azurerm_resource_group" "hub" {
  name     = "${var.range_name}-hub-rg"
  location = var.azure_region
  tags = {
    Range = var.range_name
    Tier  = "hub"
  }
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.range_name}-hub-vnet"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  address_space       = [var.hub_cidr]
}

resource "azurerm_subnet" "hub_mgmt" {
  name                 = "mgmt"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_mgmt_cidr]
}

# Separate subnet for Ghostwriter / SteppingStones / RedELK so they have
# their own NSG with operator-only ingress for the web UIs.
resource "azurerm_subnet" "hub_infra" {
  name                 = "infra"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_infra_cidr]
}

# Shared-lab subnet: home for per_student=false target machines (dc01,
# srv01, ws10, ws11, linux01, analyst) when deploying in multi-student
# `shared` mode. Lives inside the hub VNet so it's reachable from every
# per-student attacker spoke via the existing hub↔spoke peering — no
# extra peering plumbing required. Empty in single-student deploys (the
# subnet exists but no machines land in it; cost is zero — Azure doesn't
# bill for empty subnets, only for NICs / NSG rule counts).
#
# NSG below allows inbound from every spoke VNet (per-student attacker
# subnets) so every student can attack the shared targets.
resource "azurerm_subnet" "hub_shared_lab" {
  name                 = "shared-lab"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_shared_lab_cidr]
}

# Shared-lab NSG. Permissive on inbound (every per-student spoke must
# reach the targets to attack them) and on outbound (targets need DC
# replication, DNS, NTP, AD events, etc.). Lockdown happens via the
# existing geofence + spoke-side NSGs, not here.
resource "azurerm_network_security_group" "hub_shared_lab" {
  name                = "${var.range_name}-hub-shared-lab-nsg"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  # Allow inbound from the whole 10/8 range. Per-student attacker
  # spokes live at 10.<n>.0.0/22; hub-mgmt traffic for ansible / WinRM
  # admin comes from 10.0.0.0/24. One rule covers both.
  security_rule {
    name                       = "from-range"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

  # Allow outbound to anywhere — the DC needs internet for Windows
  # Update / activation / time sync; member servers need it for the
  # same. Real lockdown is layered on at the spoke-side egress rules
  # (which DENY internet when lockdown is on).
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

resource "azurerm_subnet_network_security_group_association" "hub_shared_lab" {
  subnet_id                 = azurerm_subnet.hub_shared_lab.id
  network_security_group_id = azurerm_network_security_group.hub_shared_lab.id
}

resource "azurerm_network_security_group" "hub_infra" {
  name                = "${var.range_name}-hub-infra-nsg"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  # SSH + web from operator CIDRs (also reachable through Guacamole).
  # Same chunking pattern as hub_mgmt — supports up to ~17500 CIDRs by
  # rendering one NSG rule per 3500-CIDR slice. Priorities 100-104 for
  # ssh chunks, 110-114 for web chunks.
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
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
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
    content {
      name                       = "operator-web-${security_rule.key}"
      priority                   = 110 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = ["443", "8000", "8080", "5601"]
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }
  # Allow logs from anywhere in 10/8 to RedELK on Logstash :5044 and the
  # Elastic/Kibana ports. Per-student C2 teamservers and redirectors
  # ship logs here via Filebeat (configured in their userdata).
  security_rule {
    name                       = "from-range-logs"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5044", "9200", "5601"]
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

  # Guacamole is at 10.0.0.20 (hub_mgmt subnet). When shared infra has
  # no public IP (redteam-lab pattern), operators reach SteppingStones
  # / Ghostwriter / RedELK web UIs and SSH via Guacamole's connection
  # registrations or via Kali's browser → these rules let traffic from
  # Guacamole's IP into hub_infra on the relevant ports.
  security_rule {
    name                       = "from-guacamole-ssh"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.20/32"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "from-guacamole-web"
    priority                   = 211
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443", "8000", "8080", "5601"]
    source_address_prefix      = "10.0.0.20/32"
    destination_address_prefix = "*"
  }
  # Workspaces VM kali-2 container pool: guacd at 10.0.0.20 reaches
  # 10.0.1.50:5901..5909 (one per pool slot — max 9 slots). The container
  # itself runs RFB without auth; the security boundary is THIS rule —
  # only the Guacamole VM IP can talk to the pool ports.
  security_rule {
    name                       = "from-guacamole-vnc"
    priority                   = 212
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5901-5909"
    source_address_prefix      = "10.0.0.20/32"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hub_infra" {
  subnet_id                 = azurerm_subnet.hub_infra.id
  network_security_group_id = azurerm_network_security_group.hub_infra.id
}

resource "azurerm_network_security_group" "hub_mgmt" {
  name                = "${var.range_name}-hub-mgmt-nsg"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  # Azure NSG rules cap source_address_prefixes at 4000 entries. When
  # guacamole_ingress_cidrs is geofenced (a country list expanded by the
  # generator), it can easily exceed that — for SG/AU/AE/PH/SA/QA the
  # aggregated total is ~10k CIDRs. We chunk into 3500-entry slices and
  # render one NSG rule per chunk. Priority numbering reserves blocks
  # 100-104 (https), 110-114 (ssh), 120-124 (kibana) — supporting up to
  # 5 chunks each (≈ 17500 CIDRs).
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
    content {
      name                       = "guacamole-https-${security_rule.key}"
      priority                   = 100 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  # Let's Encrypt HTTP-01 challenge for guacamole.<domain>. Port 80
  # open to the world (no source restriction) — required for ACME
  # validation from LE's distributed validators, and for cert renewal
  # every ~60 days. nginx redirects all port-80 traffic except
  # /.well-known/acme-challenge/* to HTTPS so this is harmless.
  security_rule {
    name                       = "guacamole-acme-http"
    priority                   = 150
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # SSH to hub for emergency operator access (restrict in real ops)
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
    content {
      name                       = "operator-ssh-${security_rule.key}"
      priority                   = 110 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  # Kibana from operator CIDRs
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
    content {
      name                       = "kibana-${security_rule.key}"
      priority                   = 120 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "5601"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  # All traffic from any peered student VNet (10.0.0.0/8 covers our plan).
  # Filebeat/Winlogbeat from student targets land here on 5044/9200/etc.
  security_rule {
    name                       = "from-students"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hub_mgmt" {
  subnet_id                 = azurerm_subnet.hub_mgmt.id
  network_security_group_id = azurerm_network_security_group.hub_mgmt.id
}
