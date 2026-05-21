################################################################################
# Per-student resources (RG + VNet + subnets + NSGs + peering + NAT).
#
# All of these are keyed by student_id so add/remove a student is a clean
# `terraform apply`. Spokes peer ONLY to the hub — student VNets are
# isolated from each other.
################################################################################

locals {
  # All distinct student ids from var.machines. INCLUDES the special "" id
  # used by per_student=false (shared) machines in multi-student `shared`
  # mode. Every map keyed by student_id (passwords, listeners, outputs)
  # uses THIS list so the "" key resolves to the cohort-shared value (the
  # shared domain admin password, the shared BRC4 listener config, etc.).
  students = distinct([for m in var.machines : m.student_id])

  # Whether this deploy has ANY shared-mode machines (machines with
  # student_id="" coexisting with one or more real per-student ids).
  # True in multi-student `shared` mode (e.g. student-redteam-lab with
  # --students 3 emits ["", "lab01", "lab02", "lab03"]). False in
  # single-student / solo deploys (just [""]).
  multi_student_shared = (
    contains(local.students, "")
    && length(local.students) > 1
  )

  # Subset of `students` that get per-student NETWORK resources (RG,
  # VNet, attacker subnet, targets subnet, NSGs, hub peering, NAT).
  # The "" id is filtered OUT in multi-student shared mode — its
  # machines live in the hub's shared-lab subnet, not in a per-student
  # spoke. In single-student mode the "" id is kept so the existing
  # single-student spoke (10.<student_index=1>.0.0/22) is created
  # exactly as before this refactor.
  per_student_spokes = (
    local.multi_student_shared
    ? [for sid in local.students : sid if sid != ""]
    : local.students
  )

  # student_id -> { index, cidr, targets_cidr, attacker_cidr }
  # Only computed for per_student_spokes — the "" student in
  # multi-student-shared mode has no spoke, so no student_meta entry.
  # vms.tf's machine_subnet dispatch detects student_id="" + shared
  # mode and routes those machines to the hub instead.
  student_meta = {
    for sid in local.per_student_spokes :
    sid => {
      # student_index is the same for every machine in a student's group;
      # take it from the first matching machine.
      index         = [for m in var.machines : m.student_index if m.student_id == sid][0]
      cidr          = format("10.%d.0.0/22", [for m in var.machines : m.student_index if m.student_id == sid][0])
      targets_cidr  = format("10.%d.0.0/24", [for m in var.machines : m.student_index if m.student_id == sid][0])
      attacker_cidr = format("10.%d.1.0/24", [for m in var.machines : m.student_index if m.student_id == sid][0])
    }
  }
}

resource "azurerm_resource_group" "student" {
  for_each = toset(local.per_student_spokes)
  name     = "${var.range_name}-${each.key == "" ? "single" : each.key}-rg"
  location = var.azure_region
  tags = {
    Range     = var.range_name
    StudentId = each.key
    Tier      = "student"
  }
}

resource "azurerm_virtual_network" "student" {
  for_each            = toset(local.per_student_spokes)
  name                = "${var.range_name}-${each.key == "" ? "single" : each.key}-vnet"
  resource_group_name = azurerm_resource_group.student[each.key].name
  location            = azurerm_resource_group.student[each.key].location
  address_space       = [local.student_meta[each.key].cidr]
}

resource "azurerm_subnet" "targets" {
  for_each             = toset(local.per_student_spokes)
  name                 = "targets"
  resource_group_name  = azurerm_resource_group.student[each.key].name
  virtual_network_name = azurerm_virtual_network.student[each.key].name
  address_prefixes     = [local.student_meta[each.key].targets_cidr]
}

resource "azurerm_subnet" "attacker" {
  for_each             = toset(local.per_student_spokes)
  name                 = "attacker"
  resource_group_name  = azurerm_resource_group.student[each.key].name
  virtual_network_name = azurerm_virtual_network.student[each.key].name
  address_prefixes     = [local.student_meta[each.key].attacker_cidr]
}

# ---- NSGs ---------------------------------------------------------------
# Targets NSG: allow intra-VNet, allow from hub, deny inbound from
# attacker subnet (forces students to compromise via Guacamole+attacker
# pivot rather than direct LAN). Egress: allow only to VNet + hub by default.

resource "azurerm_network_security_group" "targets" {
  for_each            = toset(local.per_student_spokes)
  name                = "${var.range_name}-${each.key == "" ? "single" : each.key}-targets-nsg"
  resource_group_name = azurerm_resource_group.student[each.key].name
  location            = azurerm_resource_group.student[each.key].location

  # Inbound from same VNet (intra-target lateral movement)
  security_rule {
    name                       = "intra-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
  # Inbound from hub (Guacamole RDP/SSH + ELK agent push)
  security_rule {
    name                       = "from-hub"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.hub_cidr
    destination_address_prefix = "*"
  }
  # Inbound from attacker subnet (the student's pivot)
  security_rule {
    name                       = "from-attacker"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.student_meta[each.key].attacker_cidr
    destination_address_prefix = "*"
  }
  # Block all other inbound
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

  # Egress: VNet + hub always allowed; internet only when NOT lockdown
  security_rule {
    name                       = "out-vnet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "out-hub"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = var.hub_cidr
  }
  security_rule {
    name                       = "out-internet-build"
    priority                   = 200
    direction                  = "Outbound"
    access                     = var.lockdown ? "Deny" : "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "targets" {
  for_each                  = toset(local.per_student_spokes)
  subnet_id                 = azurerm_subnet.targets[each.key].id
  network_security_group_id = azurerm_network_security_group.targets[each.key].id
}

# Attacker NSG: allow from hub (Guacamole) + intra-VNet; egress is wide
# during build, restricted on lockdown to VNet + hub only (no internet).
resource "azurerm_network_security_group" "attacker" {
  for_each            = toset(local.per_student_spokes)
  name                = "${var.range_name}-${each.key == "" ? "single" : each.key}-attacker-nsg"
  resource_group_name = azurerm_resource_group.student[each.key].name
  location            = azurerm_resource_group.student[each.key].location

  # ---- C2 stack port enforcement (per-student teamservers) --------------
  # All three C2 frameworks live in the per-student attacker subnet
  # (Adaptix .5, Mythic .7, BRC4 .9). The commander/operator port is
  # Kali-only; the :8443–:8447 listener ports are paired-redirector-only.
  # Adaptix + BRC4 use :9000; Mythic uses upstream-default :7443.
  #
  # Azure NSG priorities must be in [100, 4096]. The C2 rules sit at
  # 100–105 (specific allows + denies) — they MUST fire before from-hub
  # (106) so even hub-sourced traffic can't reach the commander/listener
  # ports unless it's specifically the kali/redirector source IP. The
  # broad intra-vnet allow at 110 fires last.
  security_rule {
    name                    = "kali-to-commander"
    priority                = 100
    direction               = "Inbound"
    access                  = "Allow"
    protocol                = "Tcp"
    source_port_range       = "*"
    destination_port_ranges = ["7443", "9000", "31337"]
    source_address_prefix   = format("10.%d.1.20/32", local.student_meta[each.key].index)
    destination_address_prefixes = [
      format("10.%d.1.5/32", local.student_meta[each.key].index),  # Adaptix :9000
      format("10.%d.1.7/32", local.student_meta[each.key].index),  # Mythic  :7443
      format("10.%d.1.9/32", local.student_meta[each.key].index),  # BRC4    :9000
      format("10.%d.1.11/32", local.student_meta[each.key].index), # Sliver  :31337
    ]
  }
  security_rule {
    name                    = "deny-commander-other"
    priority                = 101
    direction               = "Inbound"
    access                  = "Deny"
    protocol                = "Tcp"
    source_port_range       = "*"
    destination_port_ranges = ["7443", "9000", "31337"]
    source_address_prefix   = "*"
    destination_address_prefixes = [
      format("10.%d.1.5/32", local.student_meta[each.key].index),
      format("10.%d.1.7/32", local.student_meta[each.key].index),
      format("10.%d.1.9/32", local.student_meta[each.key].index),
      format("10.%d.1.11/32", local.student_meta[each.key].index),
    ]
  }
  security_rule {
    name                       = "redir-adaptix-to-listeners"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8443-8447"
    source_address_prefix      = format("10.%d.1.6/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.5/32", local.student_meta[each.key].index)
  }
  security_rule {
    name                       = "redir-mythic-to-listeners"
    priority                   = 103
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8443-8447"
    source_address_prefix      = format("10.%d.1.8/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.7/32", local.student_meta[each.key].index)
  }
  security_rule {
    name                       = "redir-brc4-to-listeners"
    priority                   = 104
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8443-8447"
    source_address_prefix      = format("10.%d.1.10/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.9/32", local.student_meta[each.key].index)
  }
  security_rule {
    name                       = "redir-sliver-to-listeners"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8443-8447"
    source_address_prefix      = format("10.%d.1.12/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.11/32", local.student_meta[each.key].index)
  }
  # ---- DoH leg: sliver DNS listener on :5353/UDP -------------------------
  # Only the sliver redirector (.12) gets DoH→raw-DNS access to sliver's
  # DNS listener. Beacons never connect here — they hit AFD anycast, the
  # redirector unwraps the DoH POST, then this internal UDP forward
  # reaches sliver. C2 has no public IP, so there's zero external surface
  # on :5353 regardless.
  #
  # Caveat: the intra-vnet allow at 110 will still permit UDP 5353 from
  # any other spoke host as a defense-in-depth gap. Tightening that
  # requires moving intra-vnet to a later priority + adding a UDP-5353
  # deny rule — leaving it open in v1 since (a) the threat is internal-
  # only and (b) the existing TCP deny at 106 is also TCP-only by design.
  security_rule {
    name                       = "redir-sliver-to-sliver-doh-udp"
    priority                   = 109
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "5353"
    source_address_prefix      = format("10.%d.1.12/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.11/32", local.student_meta[each.key].index)
  }
  # ---- Adaptix DNS listener on :53 (UDP + TCP) ---------------------------
  # adaptix teamserver (.5) hosts a BeaconDNS listener on port 53. Same
  # redirector-only access pattern as the BeaconHTTP listeners on
  # 8443-8447 (rule 102): only the adaptix redirector (.6) may reach
  # the teamserver on the DNS port. UDP 53 carries the bulk of the
  # DNS C2 traffic; TCP 53 covers fallback for responses too large for
  # a single UDP datagram (RFC 1035 §4.2.2 "messages over TCP" — the
  # extender's `beacon_listener_dns/pl_transport.go` binds both).
  # Two separate rules since Azure NSG `protocol` is single-valued.
  security_rule {
    name                       = "redir-adaptix-to-dns-udp"
    priority                   = 111
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = format("10.%d.1.6/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.5/32", local.student_meta[each.key].index)
  }
  security_rule {
    name                       = "redir-adaptix-to-dns-tcp"
    priority                   = 112
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = format("10.%d.1.6/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.5/32", local.student_meta[each.key].index)
  }
  # ---- Adaptix GopherTCP listeners on :8448-:8449 ------------------------
  # adaptix teamserver (.5) hosts TWO GopherTCP listeners:
  #   :8448  gopher_GopherTCP  (primary)
  #   :8449  alt_GopherTCP     (alternate / failover)
  # Both sit above the BeaconHTTP 8443-8447 range so the existing
  # `redir-adaptix-to-listeners` rule at priority 102 doesn't need to
  # widen. Same redirector-only access pattern. NOTE: BeaconSMB and
  # BeaconTCP are INTERNAL listeners (server doesn't bind a port for
  # them) so they need no NSG change — peer pivot agents connect
  # target-to-target via the existing intra-vnet allow rule at 110.
  security_rule {
    name                       = "redir-adaptix-to-gopher"
    priority                   = 113
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8448-8449"
    source_address_prefix      = format("10.%d.1.6/32", local.student_meta[each.key].index)
    destination_address_prefix = format("10.%d.1.5/32", local.student_meta[each.key].index)
  }
  security_rule {
    name                   = "deny-listeners-other"
    priority               = 106
    direction              = "Inbound"
    access                 = "Deny"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "8443-8447"
    source_address_prefix  = "*"
    destination_address_prefixes = [
      format("10.%d.1.5/32", local.student_meta[each.key].index),
      format("10.%d.1.7/32", local.student_meta[each.key].index),
      format("10.%d.1.9/32", local.student_meta[each.key].index),
      format("10.%d.1.11/32", local.student_meta[each.key].index),
    ]
  }
  # ---- Operator SSH (so Ansible can reach redirectors directly) ---------
  # Mirrors the hub NSG's operator-ssh pattern. Operator's external IP
  # range is var.guacamole_ingress_cidrs (same list that gates Guacamole
  # web access — the operator's laptop is in here by definition since
  # they reach Guacamole from it). Targets the redirectors' public IPs
  # specifically; teamservers are still NSG-isolated and reached via
  # ProxyJump through the redirector.
  #
  # Priority 115+: deliberately avoids:
  #   100-106  C2 commander/listener rules
  #   107      afd-to-redirectors (dynamic, only when advanced_c2 enabled)
  #   108      from-hub
  #   110      intra-vnet
  # 115 is comfortably above all of those and well below deny-all-in (4000).
  # We chunk to 3500 CIDRs per rule (Azure's per-rule SourceAddressPrefixes
  # cap), so the priority counter rolls 115, 116, ... if the operator
  # has a huge ingress list.
  dynamic "security_rule" {
    for_each = chunklist(local.effective_ingress_cidrs, 3500)
    content {
      name                       = "operator-ssh-${security_rule.key}"
      priority                   = 115 + security_rule.key
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = security_rule.value
      destination_address_prefix = "*"
    }
  }

  security_rule {
    name                       = "from-hub"
    priority                   = 108
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.hub_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "intra-vnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
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

  security_rule {
    name                       = "out-vnet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "out-hub"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = var.hub_cidr
  }
  security_rule {
    name                       = "out-internet-build"
    priority                   = 200
    direction                  = "Outbound"
    access                     = var.lockdown ? "Deny" : "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  # Conditional rule: when advanced_c2 is enabled, allow Azure Front Door's
  # service-tagged source range to reach the redirectors' pinned IPs
  # (10.<n>.1.6 → Adaptix, 10.<n>.1.8 → Mythic, 10.<n>.1.10 → BRC4) on :443.
  # Inline (not a standalone azurerm_network_security_rule) so the
  # provider doesn't oscillate between treating inline vs standalone as
  # the source of truth.
  dynamic "security_rule" {
    for_each = var.advanced_c2.enabled ? [1] : []
    content {
      name                   = "afd-to-redirectors"
      priority               = 107
      direction              = "Inbound"
      access                 = "Allow"
      protocol               = "Tcp"
      source_port_range      = "*"
      destination_port_range = "443"
      source_address_prefix  = "AzureFrontDoor.Backend"
      destination_address_prefixes = [
        format("10.%d.1.6/32", local.student_meta[each.key].index),
        format("10.%d.1.8/32", local.student_meta[each.key].index),
        format("10.%d.1.10/32", local.student_meta[each.key].index),
        format("10.%d.1.12/32", local.student_meta[each.key].index),
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "attacker" {
  for_each                  = toset(local.per_student_spokes)
  subnet_id                 = azurerm_subnet.attacker[each.key].id
  network_security_group_id = azurerm_network_security_group.attacker[each.key].id
}

# ---- NAT (build-time egress) -------------------------------------------
# Provisioned only when var.lockdown == false. Apply with lockdown=false
# first so cloud-init/CSE can fetch packages, then re-apply with
# lockdown=true to remove NAT and harden.

resource "azurerm_public_ip" "nat" {
  for_each            = var.lockdown ? toset([]) : toset(local.per_student_spokes)
  name                = "${var.range_name}-${each.key == "" ? "single" : each.key}-nat-pip"
  location            = azurerm_resource_group.student[each.key].location
  resource_group_name = azurerm_resource_group.student[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "this" {
  for_each            = var.lockdown ? toset([]) : toset(local.per_student_spokes)
  name                = "${var.range_name}-${each.key == "" ? "single" : each.key}-nat"
  location            = azurerm_resource_group.student[each.key].location
  resource_group_name = azurerm_resource_group.student[each.key].name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  for_each             = var.lockdown ? toset([]) : toset(local.per_student_spokes)
  nat_gateway_id       = azurerm_nat_gateway.this[each.key].id
  public_ip_address_id = azurerm_public_ip.nat[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "targets" {
  for_each       = var.lockdown ? toset([]) : toset(local.per_student_spokes)
  subnet_id      = azurerm_subnet.targets[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "attacker" {
  for_each       = var.lockdown ? toset([]) : toset(local.per_student_spokes)
  subnet_id      = azurerm_subnet.attacker[each.key].id
  nat_gateway_id = azurerm_nat_gateway.this[each.key].id
}

# ---- Hub <-> spoke peering ----------------------------------------------
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each                  = toset(local.per_student_spokes)
  name                      = "hub-to-${each.key == "" ? "single" : each.key}"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.student[each.key].id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each                  = toset(local.per_student_spokes)
  name                      = "${each.key == "" ? "single" : each.key}-to-hub"
  resource_group_name       = azurerm_resource_group.student[each.key].name
  virtual_network_name      = azurerm_virtual_network.student[each.key].name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}
