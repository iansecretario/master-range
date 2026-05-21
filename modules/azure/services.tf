################################################################################
# Hub services: Guacamole (entry point) and ELK.
#
# The Guacamole VM is rendered with a JSON manifest of every machine + its
# private IP + creds + role + student_id. On first boot the VM brings up
# guacd+guacamole+postgres via docker compose, then a Python script uses
# Guacamole's REST API to:
#   - create one connection group per student
#   - create an RDP/SSH connection for every machine, prefilled with creds,
#     placed inside the right student's group
#   - create one Guacamole user per student, granted READ access to ONLY
#     their own connection group
#
# Because all NICs are created before this VM (depends_on below), every
# private_ip_address is already resolved at template time.
################################################################################

locals {
  # Map of lab_users name → password (for assigned_user lookups below).
  # When domain.lab_users is empty (default), this is `{}` and no
  # extra connections get registered.
  _lab_user_pwd = { for u in var.domain.lab_users : u.name => u.password }

  # Convenience flag — services.workspaces is optional() in variables.tf,
  # so guard with try() in case a stale tfvars omits the key entirely.
  _workspaces_enabled = try(var.services.workspaces.enabled, false)

  # ELK as a Guacamole-registered SSH connection. When public_ip is
  # off, this is the only easy way for an operator to ssh in. Always
  # registered when ELK is enabled — same shape as a shared infra entry.
  _elk_guac_entry = var.services.elk.enabled ? [{
    name        = "elk"
    base_name   = "elk"
    student_id  = "shared-infra"
    role        = "elk"
    os          = "ubuntu-22"
    hostname    = "10.0.0.10"
    protocol    = "ssh"
    username    = "elkadmin"
    password    = var.services.elk.kibana_password
    port        = 22
    domain_join = false
    # SFTP overlay on EVERY Linux connection — gives the operator a
    # file-browser side panel (upload + download) in addition to the
    # shell. Operator explicitly asked for download capability on all
    # machines. ELK's elkadmin home is the landing dir.
    sftp = {
      enabled          = true
      hostname         = "10.0.0.10"
      port             = 22
      username         = "elkadmin"
      password         = var.services.elk.kibana_password
      root-directory   = "/home/elkadmin"
      directory        = "/home/elkadmin"
      disable-upload   = false
      disable-download = false
    }
  }] : []

  # Build the connection manifest.
  #   1. Base entry per per-student machine: Windows = RDP-as-local-admin,
  #      Linux = SSH-as-ranger.
  #   2. Per Windows member with `assigned_user` set: extra RDP entry
  #      logging in as that domain user (the "regular domain user" tier).
  #   3. Per Linux machine with `enable_root_ssh: true`: extra SSH entry
  #      logging in as root.
  #   4. Per shared-infra box: SSH entry.
  #   5. ELK SSH entry (always when ELK is enabled).
  guac_connections = concat(
    # 1. Base per-machine
    [
      for m in var.machines : {
        name       = m.name
        base_name  = m.base_name
        student_id = m.student_id
        role       = m.role
        os         = m.os
        hostname   = azurerm_network_interface.machine[m.name].private_ip_address
        # Protocol per role:
        #   - Windows machines    -> RDP/3389 (always)
        #   - Linux "attacker"    -> VNC/5901 (Kali; TigerVNC's Xtigervnc
        #                            on display :1 runs xfce4-session.
        #                            We migrated off xrdp+xorgxrdp after
        #                            spending 10+ hours patching 10+
        #                            config issues — vsock, [Xorg],
        #                            GLAMOR, DRMDevice, Virtual screen,
        #                            session policy, fuse, etc. TigerVNC
        #                            is one apt + one systemd unit and
        #                            "just works" in cloud VMs without
        #                            any DRM/GPU dance.)
        #   - any other Linux     -> SSH/22 (servers, redirectors, targets)
        protocol = (
          local.is_windows[m.name] ? "rdp" :
          # The Kali attacker workstation routes to RDP/3389: the kali
          # ansible role runs xrdp with an Xvnc backend (autorun=Xvnc),
          # which "just works" on cloud VMs without the Xorg/GPU dance.
          # Any OTHER attacker box (e.g. the kali-2 ephemeral container
          # pool, if re-enabled) still falls through to VNC/5901.
          m.base_name == "kali"       ? "rdp" :
          m.role == "attacker"        ? "vnc" :
          "ssh"
        )
        username = local.is_windows[m.name] ? m.win_admin_user : m.linux_user
        # Use the ACTUAL Azure-provisioned admin password for Windows
        # boxes, not m.win_admin_password from the scenario YAML.
        # vms.tf sets `admin_password = local.effective_domain_password[student_id]`
        # at VM-create time (random_password.domain_admin), so that's
        # what Windows actually accepts on the wire. The YAML's
        # win_admin_password is a relic of the pre-random-password era
        # and would be wrong for any deploy using random_password.*.
        password = local.is_windows[m.name] ? local.effective_domain_password[m.student_id] : m.linux_password
        port = (
          local.is_windows[m.name] ? 3389 :
          m.base_name == "kali"       ? 3389 :
          m.role == "attacker"        ? 5901 :
          22
        )
        domain_join = m.domain_join
        # SFTP overlay on EVERY Linux connection — the `kali` attacker
        # box, all C2 teamservers + redirectors, and linux-target. Gives
        # the operator a file-browser side panel (upload AND download)
        # in Guacamole regardless of the display/shell protocol.
        # Operator explicitly wants download capability on all machines
        # for testing.
        #
        # Windows machines are excluded: they get RDP drive redirection
        # (native, bidirectional — wired up in register.py). The `kali`
        # box is RDP-protocol but Linux underneath, and Guacamole RDP
        # drive redirection is disabled for Linux xrdp (chansrv crash
        # bug) — so it falls into the SFTP-overlay bucket here just like
        # the SSH boxes.
        #
        # SSH connections always reach :22; the `kali` box also runs
        # sshd, so port 22 is the SFTP transport everywhere. Landing dir
        # is the user's home (kali specifically uses ~/Downloads, which
        # the kali ansible role pre-creates).
        sftp = local.is_windows[m.name] ? null : {
          enabled          = true
          hostname         = azurerm_network_interface.machine[m.name].private_ip_address
          port             = 22
          username         = m.linux_user
          password         = m.linux_password
          root-directory   = "/home/${m.linux_user}"
          directory        = m.role == "attacker" ? "/home/${m.linux_user}/Downloads" : "/home/${m.linux_user}"
          disable-upload   = false
          disable-download = false
        }
      }
    ],
    # 2. Extra Windows RDP-as-domain-user (regular user tier). Windows
    #    does not get SFTP — see note in block 1.
    [
      for m in var.machines : {
        name        = "${m.name} (${m.assigned_user}@${var.domain.netbios})"
        base_name   = m.base_name
        student_id  = m.student_id
        role        = m.role
        os          = m.os
        hostname    = azurerm_network_interface.machine[m.name].private_ip_address
        protocol    = "rdp"
        username    = "${var.domain.netbios}\\${m.assigned_user}"
        password    = lookup(local._lab_user_pwd, m.assigned_user, "")
        port        = 3389
        domain_join = m.domain_join
        sftp        = null
      }
      if local.is_windows[m.name] && m.assigned_user != "" && contains(keys(local._lab_user_pwd), m.assigned_user)
    ],
    # 3. Extra Linux SSH-as-root.
    [
      for m in var.machines : {
        name       = "${m.name} (root)"
        base_name  = m.base_name
        student_id = m.student_id
        role       = m.role
        os         = m.os
        hostname   = azurerm_network_interface.machine[m.name].private_ip_address
        protocol   = "ssh"
        username   = "root"
        # Linux root password = per-student domain admin password (set in
        # linux-target.sh / linux-persona.sh when enable_root_ssh=true).
        password    = local.effective_domain_password[m.student_id]
        port        = 22
        domain_join = false
        # SSH-as-root entry — SFTP overlay rooted at `/` so the operator
        # can pull files from anywhere on the box (logs under /var,
        # configs under /etc, etc.), not just a home dir.
        sftp = {
          enabled          = true
          hostname         = azurerm_network_interface.machine[m.name].private_ip_address
          port             = 22
          username         = "root"
          password         = local.effective_domain_password[m.student_id]
          root-directory   = "/"
          directory        = "/root"
          disable-upload   = false
          disable-download = false
        }
      }
      if !local.is_windows[m.name] && m.enable_root_ssh
    ],
    # 4. Shared infra (Ghostwriter / SteppingStones / RedELK).
    [
      for s in var.shared_machines : {
        name        = s.name
        base_name   = s.name
        student_id  = "shared-infra"
        role        = s.role
        os          = s.os
        hostname    = azurerm_network_interface.shared[s.name].private_ip_address
        protocol    = "ssh"
        username    = s.linux_user
        password    = s.linux_password
        port        = 22
        domain_join = false
        # SFTP overlay on shared infra too (Ghostwriter / SteppingStones
        # / RedELK) — operator can pull case files, logs, configs via
        # the Guacamole file panel. Landing dir = the box's linux_user
        # home.
        sftp = {
          enabled          = true
          hostname         = azurerm_network_interface.shared[s.name].private_ip_address
          port             = 22
          username         = s.linux_user
          password         = s.linux_password
          root-directory   = "/home/${s.linux_user}"
          directory        = "/home/${s.linux_user}"
          disable-upload   = false
          disable-download = false
        }
      }
    ],
    # 5. ELK
    local._elk_guac_entry,
    # 6. Ephemeral Kali workspace pool. Each slot is a kali-2 container
    #    on the workspaces VM at 10.0.1.50, host port 5901..5900+pool_size,
    #    NAT'd to the container's :5901 RFB listener. Guac shows them as
    #    kali-2-1..N — operators pick a slot, get a fresh container (or
    #    a recycled-idle one). RFB has no auth at the container; the
    #    hub_infra NSG restricts host-port access to the Guac VM IP.
    local._workspaces_enabled ? [
      for i in range(1, var.services.workspaces.pool_size + 1) : {
        name        = "kali-2-${i}"
        base_name   = "kali-2"
        student_id  = "shared-infra"
        role        = "attacker"
        os          = "kali-rolling"
        hostname    = "10.0.1.50"
        protocol    = "vnc"
        # No auth on the container's RFB; pool slots are pre-authorized
        # by the Guacamole connection grant (operator must be in the
        # shared-infra group). Pass an empty password / username.
        username    = ""
        password    = ""
        port        = 5900 + i
        domain_join = false
        # kali-2 containers don't run sshd inside (the container is
        # ephemeral, restarts wipe state — SFTP into it would lose
        # uploads on the next recycle). Operators who need persistent
        # file transfer use the regular `kali` VM connection above.
        sftp        = null
      }
    ] : [],
  )

  guac_manifest = jsonencode({
    admin = {
      username = var.services.guacamole.admin_user
      password = local.effective_guacamole_admin_password
    }
    students     = var.student_users
    connections  = local.guac_connections
    autoregister = var.services.guacamole.autoregister
  })
}

# ---- ELK VM (must exist before Guacamole so its IP is known) -----------
resource "azurerm_network_interface" "elk" {
  count               = var.services.elk.enabled ? 1 : 0
  name                = "${var.range_name}-elk-nic"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hub_mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.10"
    public_ip_address_id          = var.services.elk.public_ip ? azurerm_public_ip.elk[0].id : null
  }
}

resource "azurerm_public_ip" "elk" {
  count               = var.services.elk.enabled && var.services.elk.public_ip ? 1 : 0
  name                = "${var.range_name}-elk-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_linux_virtual_machine" "elk" {
  count                           = var.services.elk.enabled ? 1 : 0
  name                            = "${var.range_name}-elk"
  resource_group_name             = azurerm_resource_group.hub.name
  location                        = azurerm_resource_group.hub.location
  size                            = "Standard_B4ms"
  admin_username                  = "elkadmin"
  admin_password                  = var.services.elk.kibana_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.elk[0].id]

  priority        = var.vm_priority
  eviction_policy = var.vm_priority == "Spot" ? "Deallocate" : null
  max_bid_price   = var.vm_priority == "Spot" ? -1 : null

  custom_data = base64encode(templatefile("${path.module}/userdata/elk.sh", {
    kibana_user     = var.services.elk.kibana_user
    kibana_password = var.services.elk.kibana_password
  }))

  os_disk {
    name                 = "${var.range_name}-elk-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 100
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = { Range = var.range_name, Tier = "hub", Service = "elk" }
}

# ---- Guacamole VM ------------------------------------------------------
resource "azurerm_public_ip" "guacamole" {
  count               = var.services.guacamole.enabled ? 1 : 0
  name                = "${var.range_name}-guac-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  # Request an Azure-assigned cloudapp.azure.com hostname ONLY when the
  # operator hasn't supplied a custom hostname via
  # services.guacamole.dns_zone_name + custom_hostname. When a custom
  # FQDN exists, the cloudapp URL becomes a duplicate that leaks the
  # underlying Azure region/subscription naming; better to leave the
  # label null so that the cyberwarrange.com (or whatever) hostname is
  # the only way in. To keep backwards-compat for scenarios without a
  # custom domain (e.g. quick lab spin-ups), the cloudapp label stays.
  domain_name_label = local.guac_custom_enabled ? null : "${var.range_name}-${random_string.dns_suffix.result}"
}

resource "random_string" "dns_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_network_interface" "guacamole" {
  count               = var.services.guacamole.enabled ? 1 : 0
  name                = "${var.range_name}-guac-nic"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hub_mgmt.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.20"
    public_ip_address_id          = azurerm_public_ip.guacamole[0].id
  }
}

resource "azurerm_linux_virtual_machine" "guacamole" {
  count                           = var.services.guacamole.enabled ? 1 : 0
  name                            = "${var.range_name}-guac"
  resource_group_name             = azurerm_resource_group.hub.name
  location                        = azurerm_resource_group.hub.location
  size                            = "Standard_B2ms"
  admin_username                  = "guacadmin"
  admin_password                  = local.effective_guacamole_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.guacamole[0].id]

  priority        = var.vm_priority
  eviction_policy = var.vm_priority == "Spot" ? "Deallocate" : null
  max_bid_price   = var.vm_priority == "Spot" ? -1 : null

  # System-assigned managed identity gives the VM an Azure AD identity
  # that we can grant DNS Zone Contributor on the cyberwarrange.com
  # zone (see role assignment below). certbot-dns-azure uses this MSI
  # for the DNS-01 challenge — no SP credentials in cloud-init.
  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/userdata/guacamole.sh", {
    admin_user     = var.services.guacamole.admin_user
    admin_password = local.effective_guacamole_admin_password
    manifest_b64   = base64encode(local.guac_manifest)
    # Prefer the custom <hostname>.<domain> when configured; falls back
    # to the Azure-assigned cloudapp FQDN. See guacamole_dns.tf for the
    # `local.guac_effective_fqdn` derivation.
    guac_fqdn       = local.guac_effective_fqdn
    # IMPORTANT: must be a well-formed email — certbot rejects raw
    # usernames here. Earlier this was wired to `admin_user` ("guacadmin"),
    # which silently broke LE issuance and dropped HTTPS to self-signed.
    guac_acme_email = var.services.guacamole.acme_email
    # The operator SSH public key — same key planted on every other
    # Linux VM via cloud-init. Lets Ansible reach guacadmin@<guac>
    # over SSH without juggling the random admin password.
    ssh_pubkey = local.effective_ssh_pubkey
    # Wildcard cert plumbing. When dns_zone_name is set, the bootstrap
    # script switches from HTTP-01 (per-FQDN) to DNS-01 (wildcard,
    # `*.<zone>` + apex). Authenticates to Azure DNS via the VM's
    # system-assigned managed identity — the role assignment below
    # gives it write access to the zone. Empty values disable
    # wildcard mode and fall back to HTTP-01 per-FQDN.
    guac_wildcard_zone     = var.services.guacamole.dns_zone_name
    guac_wildcard_zone_rg  = var.services.guacamole.dns_zone_resource_group
    guac_wildcard_zone_sub = var.services.guacamole.dns_zone_subscription_id
    # Key Vault for wildcard cert caching. cloud-init reads the cert
    # from here first (if present + valid), and writes it back after
    # a successful lego issue/renew. Bypasses LE rate limits on
    # destroy/redeploy cycles since the cert outlives the VM.
    guac_kv_name = azurerm_key_vault.lab.name
  }))

  os_disk {
    name                 = "${var.range_name}-guac-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 50
  }

  # Prefer the pre-baked Guacamole SIG image when available (skips ~5-8 min
  # of docker install + nginx install + guac image pulls on first boot).
  # Falls back to the Marketplace Ubuntu 22.04 SKU when no baked version
  # exists yet. Operator workflow:
  #   ./range bake guacamole       # one-time, ~20-25 min
  #   set baking.use_baked_guacamole: true in scenario YAML
  #   ./range apply                # subsequent applies pull from SIG
  source_image_id = local.baked_guacamole_id

  dynamic "source_image_reference" {
    for_each = local.baked_guacamole_id == null ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
  }

  tags = { Range = var.range_name, Tier = "hub", Service = "guacamole" }

  # Guarantees every NIC's private_ip_address is resolved before render.
  depends_on = [
    azurerm_network_interface.machine,
    azurerm_network_interface.shared,
  ]

  # Same rationale as the Linux VM resource (modules/azure/vms.tf):
  # cloud-init userdata changes should not force-replace a running
  # box — destroying Guacamole would wipe the 20 registered RDP
  # connections + the operator's LE cert state. Reapply userdata
  # changes manually via `./range fix <vm> --legacy` (re-runs the
  # current cloud-init via az run-command) if you need to pick up
  # a new key/config in place.
  lifecycle {
    ignore_changes = [custom_data]
  }
}


# NOTE: no DNS A record needed for Guacamole — it uses the Azure-assigned
# cloudapp.azure.com FQDN (set via domain_name_label on the public IP).
# That FQDN is publicly resolvable as soon as the public IP is created;
# certbot bootstraps the Let's Encrypt cert against it on first boot.
# Keeping enterprisestudio.com unused by Guacamole leaves it dedicated
# to C2 redirector fronting.

# ---- Workspaces VM (ephemeral Kali container pool) ----------------------
# Dedicated host for kali-2 ephemeral containers. NOT co-located with the
# Guac VM — see the long explainer in userdata/workspaces.sh and in the
# `services.workspaces` variable doc. Lives in hub_infra (10.0.1.50);
# guacd reaches it on 5901..590N via the hub_infra NSG's
# `from-guacamole-vnc` rule (defined in hub.tf).

resource "azurerm_network_interface" "workspaces" {
  count               = local._workspaces_enabled ? 1 : 0
  name                = "${var.range_name}-workspaces-nic"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.hub_infra.id
    private_ip_address_allocation = "Static"
    # Pinned so the Guacamole connection manifest can hardcode it as the
    # hostname for kali-2-<i> entries (rendered at template time before
    # the VM exists — chicken/egg avoided by using a fixed IP).
    private_ip_address            = "10.0.1.50"
  }
}

resource "azurerm_linux_virtual_machine" "workspaces" {
  count                           = local._workspaces_enabled ? 1 : 0
  name                            = "${var.range_name}-workspaces"
  resource_group_name             = azurerm_resource_group.hub.name
  location                        = azurerm_resource_group.hub.location
  size                            = var.services.workspaces.vm_size
  admin_username                  = "workspaces"
  # Reuse the Guacamole admin password — same hub-tier ops boundary,
  # same operator who needs occasional SSH debug access. Operators
  # ProxyJump through the Guac VM (no public IP on workspaces) so the
  # password is only useful from inside the hub VNet.
  admin_password                  = local.effective_guacamole_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.workspaces[0].id]

  priority        = var.vm_priority
  eviction_policy = var.vm_priority == "Spot" ? "Deallocate" : null
  max_bid_price   = var.vm_priority == "Spot" ? -1 : null

  custom_data = base64encode(templatefile("${path.module}/userdata/workspaces.sh", {
    linux_user           = "workspaces"
    linux_pass           = local.effective_guacamole_admin_password
    ssh_pubkey           = local.effective_ssh_pubkey
    pool_size            = var.services.workspaces.pool_size
    auto_restart         = var.services.workspaces.auto_restart ? "true" : "false"
    restart_interval_min = var.services.workspaces.restart_interval_min
  }))

  os_disk {
    name                 = "${var.range_name}-workspaces-osdisk"
    caching              = "ReadWrite"
    # Larger than the other hub VMs — the kali-rolling image plus N
    # running container layers easily eats 15-20 GB. 80 GB gives
    # headroom for image rebuilds and per-slot tmpfs overflows.
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 80
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = { Range = var.range_name, Tier = "hub", Service = "workspaces" }

  # Same rationale as Guacamole + the per-student Linux VMs: a cloud-init
  # rewrite shouldn't force-replace a running pool host (would kill every
  # in-flight operator session and force a 15-min image rebuild). Reapply
  # via `./range fix workspaces --legacy` if needed.
  lifecycle {
    ignore_changes = [custom_data]
  }
}
