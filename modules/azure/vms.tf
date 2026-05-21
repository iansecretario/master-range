################################################################################
# Per-machine VMs.
#
# We treat Linux and Windows as two for_each maps so we can use the
# right resource type (azurerm_linux_virtual_machine vs
# azurerm_windows_virtual_machine). User data is rendered via
# templatefile() against the matching userdata/*.{sh,ps1} file for the role.
################################################################################

locals {
  # Bootstrap payload per machine.
  bootstrap = {
    for m in var.machines :
    m.name => (
      m.role == "windows-blank" ? templatefile("${path.module}/userdata/windows-blank.ps1", {
        local_admin = m.win_admin_user
        # windows-blank gets the per-student random password too, so
        # ansible bridge can authenticate uniformly across students.
        local_password = local.effective_domain_password[m.student_id]
      }) :
      m.role == "windows-analyst" ? templatefile("${path.module}/userdata/windows-analyst.ps1", {
        local_admin    = m.win_admin_user
        local_password = local.effective_domain_password[m.student_id]
      }) :
      m.role == "windows-dc" ? templatefile("${path.module}/userdata/windows-dc.ps1", {
        domain_fqdn       = var.domain.fqdn
        netbios           = var.domain.netbios
        admin_user        = var.domain.admin_user
        admin_password    = local.effective_domain_password[m.student_id]
        safemode_password = var.domain.safemode_password
        local_admin       = m.win_admin_user
        local_password    = local.effective_domain_password[m.student_id]
        elk_endpoint      = "10.0.0.10"
        kibana_password   = var.services.elk.kibana_password
        deploy_agents     = var.services.elk.deploy_agents
        student_id        = m.student_id
        # Winlogbeat YAML pre-built in terraform and base64'd to avoid
        # the PowerShell here-string parser's misbehavior on multi-line
        # "- name: ..." content. DC ships DS + DNS event logs in addition
        # to the standard Application/System/Security/Sysmon set.
        winlogbeat_b64 = base64encode(join("\n", [
          "winlogbeat.event_logs:",
          "  - name: Application",
          "  - name: System",
          "  - name: Security",
          "  - name: Microsoft-Windows-Sysmon/Operational",
          "  - name: Directory Service",
          "  - name: DNS Server",
          "output.elasticsearch:",
          "  hosts: [\"http://10.0.0.10:9200\"]",
          "  username: elastic",
          "  password: \"${var.services.elk.kibana_password}\"",
          "",
        ]))
        # Lab speed knob — when true, DC skips Windows Update on
        # first boot (saves ~10-15 min) and is paired with a D8s_v5
        # SKU bump in images.tf so AD promo runs faster.
        fast_windows = var.fast_windows ? "true" : "false"
        # Optional list of regular domain users to seed at promotion;
        # rendered as a JSON literal that Phase 2 parses with
        # ConvertFrom-Json. Empty list (default) → no users seeded.
        lab_users_json = jsonencode(var.domain.lab_users)
      }) :
      contains(["windows-member", "windows-workstation"], m.role) ? (
        m.persona_name != "" ? templatefile("${path.module}/userdata/windows-persona.ps1", {
          persona_b64    = m.persona_b64
          do_domain_join = m.domain_join
          domain_fqdn    = var.domain.fqdn
          domain_user    = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass    = local.effective_domain_password[m.student_id]
          # DC IP dispatch:
          #   - In multi-student shared mode (m.student_id=="" with other
          #     real student ids present) the DC is the SHARED dc01 in
          #     the hub's shared-lab subnet; resolve to var.hub_shared_lab_cidr's
          #     .10 host (matches dc01.static_ip in the scenario YAML).
          #   - Otherwise (single-student deploys OR per-student-target
          #     scenarios) preserve the original per-student convention:
          #     10.<student_index>.0.10 inside that student's spoke targets
          #     subnet.
          dc_ip          = (
            m.student_id == "" && local.multi_student_shared
            ? cidrhost(var.hub_shared_lab_cidr, 10)
            : format("10.%d.0.10", m.student_index)
          )
          }) : templatefile("${path.module}/userdata/windows-member.ps1", {
          local_admin     = m.win_admin_user
          local_password  = m.win_admin_password
          do_domain_join  = m.domain_join
          domain_fqdn     = var.domain.fqdn
          domain_user     = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass     = local.effective_domain_password[m.student_id]
          # DC's static IP. Same dispatch as the persona branch above:
          # shared mode → hub_shared_lab host .10 (matches dc01's YAML
          # static_ip); otherwise → per-student spoke convention
          # 10.<student_index>.0.10. Member sets this as its DNS server
          # before Resolve-DnsName so AD SRV lookups don't fall through
          # to Azure's default resolver (168.63.129.16, which can't see
          # the AD zone).
          dc_ip           = (
            m.student_id == "" && local.multi_student_shared
            ? cidrhost(var.hub_shared_lab_cidr, 10)
            : format("10.%d.0.10", m.student_index)
          )
          elk_endpoint    = "10.0.0.10"
          kibana_password = var.services.elk.kibana_password
          deploy_agents   = var.services.elk.deploy_agents
          student_id      = m.student_id
          # Winlogbeat YAML pre-built in terraform + base64'd. See the
          # DC block above for why we avoid the PS here-string parser.
          winlogbeat_b64 = base64encode(join("\n", [
            "winlogbeat.event_logs:",
            "  - name: Application",
            "  - name: System",
            "  - name: Security",
            "  - name: Microsoft-Windows-Sysmon/Operational",
            "output.elasticsearch:",
            "  hosts: [\"http://10.0.0.10:9200\"]",
            "  username: elastic",
            "  password: \"${var.services.elk.kibana_password}\"",
            "",
          ]))
        })
      ) :
      m.role == "attacker" ? templatefile("${path.module}/userdata/attacker.sh", {
        linux_user = m.linux_user
        linux_pass = m.linux_password
        ssh_pubkey = local.effective_ssh_pubkey
        student_id = m.student_id
      }) :
      m.role == "c2-server" ? templatefile("${path.module}/userdata/c2-server.sh", {
        linux_user          = m.linux_user
        linux_pass          = m.linux_password
        ssh_pubkey          = local.effective_ssh_pubkey
        teamserver_password = local.effective_adaptix_password[m.student_id]
        operator_user       = m.linux_user
        student_id          = m.student_id
        # JSON list of {name, config} entries; configure_listeners.py
        # POSTs each to /listener/create after the teamserver boots.
        listeners_json = jsonencode(local.adaptix_listeners[m.student_id])
        # RedELK Filebeat target (empty = skip Filebeat install).
        redelk_ip = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-mythic" ? templatefile("${path.module}/userdata/c2-mythic.sh", {
        linux_user            = m.linux_user
        linux_pass            = m.linux_password
        ssh_pubkey            = local.effective_ssh_pubkey
        mythic_admin_password = local.effective_mythic_password[m.student_id]
        student_id            = m.student_id
        redelk_ip             = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-brc4" ? templatefile("${path.module}/userdata/c2-brc4.sh", {
        linux_user          = m.linux_user
        linux_pass          = m.linux_password
        ssh_pubkey          = local.effective_ssh_pubkey
        brc4_license_id     = var.brc4_license_id
        brc4_activation_key = var.brc4_activation_key
        brc4_email          = var.brc4_email
        brc4_blob_url       = var.brc4_blob_url
        student_id          = m.student_id
        student_index       = m.student_index
        # Pre-rendered c2.profile JSON: 5 HTTPS listeners + commander.
        brc4_profile_json = local.brc4_profile[m.student_id]
        # RedELK Filebeat shipper config target. Empty string when no
        # RedELK box is in shared_infrastructure (Filebeat install
        # skipped in that case).
        redelk_ip = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-sliver" ? templatefile("${path.module}/userdata/c2-sliver.sh", {
        linux_user       = m.linux_user
        linux_pass       = m.linux_password
        ssh_pubkey       = local.effective_ssh_pubkey
        sliver_password  = local.effective_sliver_password[m.student_id]
        student_id       = m.student_id
        student_index    = m.student_index
        redelk_ip        = local.redelk_in_yaml ? local.redelk_hub_ip : ""
        # Five (cdn, header_name, header_value, port) tuples — sliver-server
        # creates one HTTPS listener per CDN on the matching :8443-:8447 port.
        # Auth header is enforced server-side via sliver's --aux-config flag.
        cdn_headers_json = jsonencode([
          for cdn in local.cdn_names : {
            cdn        = cdn
            header     = local.cdn_headers["sliver"][m.student_id][cdn].name
            value      = local.cdn_headers["sliver"][m.student_id][cdn].value
            port       = local.cdn_port[cdn]
          }
        ])
      }) :
      m.role == "c2-redirector" ? templatefile("${path.module}/userdata/c2-redirector.sh", {
        linux_user = m.linux_user
        linux_pass = m.linux_password
        ssh_pubkey = local.effective_ssh_pubkey
        student_id = m.student_id
        cover_url  = var.advanced_c2.cover_url
        redelk_ip  = local.redelk_in_yaml ? local.redelk_hub_ip : ""
        # Fronts-aware upstream IP. Listener PORT is selected dynamically
        # by which X-Api-* header matched (8443–8447), not by `fronts`.
        upstream_host = (
          m.fronts == "c2-mythic" ? format("10.%d.1.7", m.student_index) :
          m.fronts == "c2-brc4" ? format("10.%d.1.9", m.student_index) :
          m.fronts == "c2-sliver" ? format("10.%d.1.11", m.student_index) :
          format("10.%d.1.5", m.student_index)
        )
        # Five (header-name, UUID, port) tuples. Keys per stack come from
        # passwords.tf; the redirector chooses by `fronts:`.
        cdn_headers = [
          for cdn in local.cdn_names : {
            cdn = cdn
            name = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name
            header_var = lower(replace(local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name, "-", "_"))
            value = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].value
            port = local.cdn_port[cdn]
          }
        ]
      }) :
      (m.role == "linux-target" && m.persona_name != "") ? templatefile("${path.module}/userdata/linux-persona.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        hostname        = m.persona_name == "" ? "target-${m.student_id}" : "${m.persona_name}-${m.student_id}"
        persona_b64     = m.persona_b64
        enable_root_ssh = m.enable_root_ssh ? "true" : "false"
        # Reuse the per-student domain admin password as root's password
        # so we don't introduce yet another random_password resource. The
        # root login is operator-only via Guacamole; students still use
        # the regular `linux_user` SSH connection.
        root_password = local.effective_domain_password[m.student_id]
      }) :
      # Bare linux-target without a persona is INFRASTRUCTURE-only (e.g.
      # Splunk indexer). Keeps the ranger user for operator access; not
      # registered in the student-facing Guacamole manifest (filtered in
      # services.tf).
      templatefile("${path.module}/userdata/linux-target.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        elk_endpoint    = "10.0.0.10"
        deploy_agents   = var.services.elk.deploy_agents
        kibana_password = var.services.elk.kibana_password
        student_id      = m.student_id
        enable_root_ssh = m.enable_root_ssh ? "true" : "false"
        root_password   = local.effective_domain_password[m.student_id]
      })
    )
  }

  # Resolve target subnet + RG per machine. Three dispatch paths:
  #
  # 1. `shared` machine in multi-student mode (m.student_id == "" AND
  #    local.multi_student_shared is true): the machine is one of the
  #    cohort-shared targets (dc01, srv01, ws10, ws11, linux01, ...
  #    per_student=false). Placed in the hub's shared-lab subnet so
  #    every per-student attacker spoke can reach it via existing
  #    hub↔spoke peering. RG and location come from the hub.
  # 2. Per-student attacker-tier role (kali, analyst, c2-*) in a spoke
  #    with a real student_id: placed in that student's attacker subnet
  #    (10.<n>.1.0/24).
  # 3. Per-student target-tier role (windows-dc, windows-member,
  #    windows-workstation, linux-target) in a spoke — including the
  #    single-student deploy case where these have student_id="" but
  #    that "" student still owns its own spoke: placed in that
  #    student's targets subnet (10.<n>.0.0/24).
  machine_subnet = {
    for m in var.machines :
    m.name => (
      m.student_id == "" && local.multi_student_shared
      ? azurerm_subnet.hub_shared_lab.id
      : contains([
          "attacker", "windows-analyst",
          "c2-server", "c2-mythic", "c2-brc4", "c2-sliver",
          "c2-redirector",
        ], m.role)
        ? azurerm_subnet.attacker[m.student_id].id
        : azurerm_subnet.targets[m.student_id].id
    )
  }

  machine_rg = {
    for m in var.machines :
    m.name => (
      m.student_id == "" && local.multi_student_shared
      ? azurerm_resource_group.hub.name
      : azurerm_resource_group.student[m.student_id].name
    )
  }

  machine_location = {
    for m in var.machines :
    m.name => (
      m.student_id == "" && local.multi_student_shared
      ? azurerm_resource_group.hub.location
      : azurerm_resource_group.student[m.student_id].location
    )
  }

  # Convention for static IPs in attacker subnet:
  #   c2-server                          at 10.<n>.1.5   (Adaptix)
  #   c2-redirector fronts c2-server     at 10.<n>.1.6
  #   c2-mythic                          at 10.<n>.1.7
  #   c2-redirector fronts c2-mythic     at 10.<n>.1.8
  #   c2-brc4                            at 10.<n>.1.9
  #   c2-redirector fronts c2-brc4       at 10.<n>.1.10
  #   c2-sliver                          at 10.<n>.1.11
  #   c2-redirector fronts c2-sliver     at 10.<n>.1.12
  #   attacker (`kali`, the Kali box)    at 10.<n>.1.20
  #   windows-analyst (FLARE-VM)         at 10.<n>.1.21
  #
  # IMPORTANT: this auto-IP table only applies to PER-STUDENT machines
  # (machines in a per-student attacker spoke). Shared-mode machines
  # (student_id=="" in multi-student deploys, placed in hub_shared_lab)
  # must NOT pass through this — the format strings would compute
  # "10.0.1.X" addresses (using student_index=0) which collide with the
  # hub_infra subnet at 10.0.1.0/24. Shared machines either get their
  # static_ip from the scenario YAML (e.g. dc01 → "10.0.2.10" in the
  # hub_shared_lab subnet) or fall through to Azure DHCP.
  effective_static_ip = {
    for m in var.machines :
    m.name => (
      m.static_ip != "" ? m.static_ip :
      (m.student_id == "" && local.multi_student_shared) ? "" :
      (m.role == "c2-server" ? format("10.%d.1.5", m.student_index) :
        m.role == "c2-mythic" ? format("10.%d.1.7", m.student_index) :
        m.role == "c2-brc4" ? format("10.%d.1.9", m.student_index) :
        m.role == "c2-sliver" ? format("10.%d.1.11", m.student_index) :
        # The Kali attacker box takes the canonical .20 — other
        # components (e.g. the BRC4 commander-serve KALI_IP allow-list)
        # reference that address. There's exactly one attacker box in
        # terra-range now (the xrdp `kali`); the kali-2 ephemeral
        # container pool runs as Docker on the workspaces VM, not as a
        # `var.machines` entry, so no .20 collision is possible.
        m.role == "attacker" ? format("10.%d.1.20", m.student_index) :
        m.role == "windows-analyst" ? format("10.%d.1.21", m.student_index) :
        m.role == "c2-redirector" ? (
          m.fronts == "c2-mythic" ? format("10.%d.1.8", m.student_index) :
          m.fronts == "c2-brc4" ? format("10.%d.1.10", m.student_index) :
          m.fronts == "c2-sliver" ? format("10.%d.1.12", m.student_index) :
          format("10.%d.1.6", m.student_index)
        ) :
      "")
    )
  }

  # Public IP id for AFD-fronted redirectors. Empty for everything else.
  machine_public_ip = {
    for m in var.machines :
    m.name => (
      var.advanced_c2.enabled && m.role == "c2-redirector"
      ? azurerm_public_ip.redirector[m.name].id
      : null
    )
  }
}

resource "azurerm_network_interface" "machine" {
  for_each = { for m in var.machines : m.name => m }

  name                = "${var.range_name}-${each.value.name}-nic"
  location            = local.machine_location[each.key]
  resource_group_name = local.machine_rg[each.key]

  ip_configuration {
    name                          = "primary"
    subnet_id                     = local.machine_subnet[each.key]
    private_ip_address_allocation = local.effective_static_ip[each.key] == "" ? "Dynamic" : "Static"
    private_ip_address            = local.effective_static_ip[each.key] == "" ? null : local.effective_static_ip[each.key]
    public_ip_address_id          = local.machine_public_ip[each.key]
  }

  tags = {
    Range     = var.range_name
    Role      = each.value.role
    StudentId = each.value.student_id
  }
}

# ---- Linux VMs ----------------------------------------------------------
resource "azurerm_linux_virtual_machine" "machine" {
  for_each = {
    for m in var.machines :
    m.name => m if !local.is_windows[m.name]
  }

  name                            = "${var.range_name}-${each.value.name}"
  resource_group_name             = local.machine_rg[each.key]
  location                        = local.machine_location[each.key]
  size                            = local.vm_size[each.key]
  admin_username                  = each.value.linux_user
  admin_password                  = each.value.linux_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.machine[each.key].id]

  custom_data = base64encode(local.bootstrap[each.key])

  # Spot pricing — only when var.vm_priority == "Spot". Eviction policy
  # "Deallocate" preserves the OS disk so an operator-side `az vm start`
  # brings the box back with state intact. max_bid_price = -1 means
  # "accept up to PAYG rate" (no upper bid).
  #
  # Critical-infrastructure roles are PINNED to Regular even when --spot
  # is set globally. Eviction during their bootstrap or steady-state
  # would corrupt the range:
  #   - c2-redirector  evicts mid-AFD-cert-validation → AFD marks the
  #                    custom domain Rejected, manual taint+reapply.
  #
  # (windows-dc is in the Windows resource block below — same pin.)
  priority        = contains(local.spot_pinned_roles, each.value.role) ? "Regular" : var.vm_priority
  eviction_policy = (contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot") ? null : "Deallocate"
  max_bid_price   = (contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot") ? null : -1

  os_disk {
    name                 = "${var.range_name}-${each.value.name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    # Role-aware sizing. The flat 30 GB default was too small for the
    # heavier roles and caused a hard disk-full wedge on the `kali`
    # box (full kali-linux-default desktop ~4 GB + the AdaptixC2
    # client built from source — Go + Qt build trees — easily 8-12 GB
    # combined, plus apt cache + logs). A disk-full Linux VM hangs
    # every write in I/O-wait: waagent can't report status, sshd
    # can't open sessions, the VM shows "running" but is unreachable.
    #
    #   attacker (`kali`)          → 128 GB  full Kali desktop + the
    #                                       from-source Adaptix build
    #   c2-sliver                  → 128 GB  sliver-server stores every
    #                                       built implant in ~/.sliver/
    #                                       slivers/<name>/ (~30 MB each)
    #                                       + the BadgerDB index. A 50-cell
    #                                       matrix run fills 64 GB in one
    #                                       go and trips SQLite's
    #                                       "database or disk is full".
    #                                       (sliver_payload role also does
    #                                       per-cell implants-rm cleanup
    #                                       but bigger disk is the durable
    #                                       fix.)
    #   other c2-* teamservers     →  64 GB  Docker image pulls
    #                                       (mythic) / source builds
    #   everything else            →  40 GB  redirectors, linux-target
    #                                       — modest, but >30 for headroom
    #
    # Increasing os_disk.disk_size_gb is an in-place update for
    # azurerm_linux_virtual_machine (NOT a force-replacement), and the
    # Azure marketplace Linux images run cloud-init growpart on boot so
    # the root partition auto-extends to fill the larger disk.
    disk_size_gb = (
      each.value.role == "attacker"                                     ? 128 :
      each.value.role == "c2-sliver"                                    ? 128 :
      contains(["c2-server", "c2-mythic", "c2-brc4"], each.value.role)  ?  64 :
      40
    )
  }

  # Prefer pre-baked SIG image (source_image_id) when available; falls
  # back to Marketplace publisher/offer/sku for OSes that haven't been
  # baked yet. Only ONE of these blocks can be present per VM resource
  # — azurerm validates this at plan time.
  #
  # `local.machine_source_image_id[each.key]` does role-aware + os-aware
  # dispatch (see images.tf) — elk/redelk/c2-redirector machines pick
  # their role-specific baked image even though their os is "debian-12",
  # while kali / windows-* dispatch on os. Returns null when no baked
  # image applies, in which case the dynamic source_image_reference
  # block below renders Marketplace publisher/offer/sku.
  source_image_id = local.machine_source_image_id[each.key]

  dynamic "source_image_reference" {
    for_each = local.machine_source_image_id[each.key] == null ? [1] : []
    content {
      publisher = local.image_map[each.value.os].publisher
      offer     = local.image_map[each.value.os].offer
      sku       = local.image_map[each.value.os].sku
      version   = local.image_map[each.value.os].version
    }
  }

  # Marketplace images that need terms acceptance (Kali, Win desktop) need
  # plan blocks. Only set for those.
  dynamic "plan" {
    for_each = each.value.os == "kali" ? [1] : []
    content {
      name      = local.image_map[each.value.os].sku
      publisher = local.image_map[each.value.os].publisher
      product   = local.image_map[each.value.os].offer
    }
  }

  tags = {
    Range     = var.range_name
    Role      = each.value.role
    OS        = each.value.os
    StudentId = each.value.student_id
    Priority  = var.vm_priority
  }

  # Once the post-apply configuration layer moved from cloud-init's
  # custom_data to the Ansible playbook in modules/azure/ansible/,
  # changes to userdata/c2-*.sh should NOT force-replace the VM.
  # cloud-init still runs on first boot (and is the right place for
  # SSH keys, hostname, base packages, systemd units). When a VM
  # gets replaced for legitimate reasons (image change, size change,
  # NIC change), terraform will still re-run cloud-init from scratch.
  # For ongoing config drift, run `./range repair` (ansible).
  lifecycle {
    ignore_changes = [custom_data]
  }
}

# ---- Windows VMs --------------------------------------------------------
resource "azurerm_windows_virtual_machine" "machine" {
  for_each = {
    for m in var.machines :
    m.name => m if local.is_windows[m.name]
  }

  name                = "${var.range_name}-${each.value.name}"
  computer_name       = substr(replace(each.value.base_name, "_", ""), 0, 15)
  resource_group_name = local.machine_rg[each.key]
  location            = local.machine_location[each.key]
  size                = local.vm_size[each.key]
  admin_username      = each.value.win_admin_user
  # Azure-level admin password is the per-student random Domain Admin
  # value. After DC promotion this account becomes Domain Administrator.
  # Members joining use the same value via templatefile() above.
  # Students never see this — it's surfaced only via operator-only
  # `terraform output student_credentials`.
  admin_password        = local.effective_domain_password[each.value.student_id]
  network_interface_ids = [azurerm_network_interface.machine[each.key].id]
  provision_vm_agent    = true

  # Critical roles (windows-dc) stay Regular even under --spot. Eviction
  # during DC promotion produces a half-built forest that AD doesn't
  # tolerate — recovery is destroy + rebuild from scratch.
  priority        = contains(local.spot_pinned_roles, each.value.role) ? "Regular" : var.vm_priority
  eviction_policy = (contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot") ? null : "Deallocate"
  max_bid_price   = (contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot") ? null : -1

  os_disk {
    name                 = "${var.range_name}-${each.value.name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    # Role-aware disk sizing:
    #   - windows-analyst (FLARE-VM) needs 100 GB MIN; we provision 256 GB
    #     so the operator has room for samples + Ghidra/IDA caches.
    #   - everything else gets the standard 128 GB.
    disk_size_gb = each.value.role == "windows-analyst" ? 256 : 128
  }

  # Role-aware + os-aware dispatch — see comment on the same field at
  # the Linux VM resource above (line ~453) for the full rationale.
  source_image_id = local.machine_source_image_id[each.key]

  dynamic "source_image_reference" {
    for_each = local.machine_source_image_id[each.key] == null ? [1] : []
    content {
      publisher = local.image_map[each.value.os].publisher
      offer     = local.image_map[each.value.os].offer
      sku       = local.image_map[each.value.os].sku
      version   = local.image_map[each.value.os].version
    }
  }

  # Microsoft's Windows-10 / windows-11 Marketplace offers do NOT
  # require a `plan {}` block — Azure rejects the deployment with
  # "image doesn't require plan information" if one is supplied.
  # Plan blocks are only needed for third-party Marketplace images
  # that gate on terms acceptance (Kali is the example we have).

  tags = {
    Range     = var.range_name
    Role      = each.value.role
    OS        = each.value.os
    StudentId = each.value.student_id
    Priority  = var.vm_priority
  }
}

# Bootstrap script via Azure Run Command (managed RunCommand v2 resource).
#
# We *deliberately* don't use azurerm_virtual_machine_extension /
# CustomScriptExtension here. Windows CSE has hard limits that bite
# domain-promotion-sized payloads:
#
#   - commandToExecute is REQUIRED on Windows CSE (the `script` field
#     is Linux-only); commandToExecute is invoked via cmd.exe which
#     has an 8191-char command line limit. Our DC + member scripts are
#     30+ KB → blow past that immediately.
#   - Workarounds via fileUris require pre-staging the script in a
#     storage account with SAS — extra infra, extra dependency loop.
#
# RunCommand v2 (`azurerm_virtual_machine_run_command`) takes the raw
# PS script inline (up to ~256 KB), no command-line involved, no
# storage account needed. Idempotent for our scripts (DC promo + member
# join short-circuit when already done), so re-runs are safe.
#
# We split into TWO resources so domain members can depends_on the DC's
# RunCommand completion (not just the DC VM existing). Without the
# split, members race the DC: they fire in parallel, hit an
# unpromoted DC, sit in their wait loop, and eventually trip Azure's
# RunCommand timeout (60 min default) → terraform reports "context
# deadline exceeded".
#
# Default terraform timeout for this resource type is 30 min; we bump
# to 90 min to accommodate Windows-Update-first-boot + AD promo + reboot.

resource "azurerm_virtual_machine_run_command" "windows_dc" {
  for_each = {
    for m in var.machines :
    m.name => m if local.is_windows[m.name] && m.role == "windows-dc"
  }

  name               = "bootstrap"
  virtual_machine_id = azurerm_windows_virtual_machine.machine[each.key].id
  location           = local.machine_location[each.key]

  source {
    script = local.bootstrap[each.key]
  }

  timeouts {
    create = "90m"
    update = "90m"
    delete = "30m"
  }

  depends_on = [azurerm_windows_virtual_machine.machine]
}

resource "azurerm_virtual_machine_run_command" "windows_members" {
  for_each = {
    for m in var.machines :
    m.name => m if local.is_windows[m.name] && m.role != "windows-dc"
  }

  name               = "bootstrap"
  virtual_machine_id = azurerm_windows_virtual_machine.machine[each.key].id
  location           = local.machine_location[each.key]

  source {
    script = local.bootstrap[each.key]
  }

  timeouts {
    create = "90m"
    update = "90m"
    delete = "30m"
  }

  # Wait for the DC's bootstrap RunCommand to complete (AD promotion +
  # reboot done) before members try to join. The DC's RunCommand only
  # returns success when the promo flow finishes; members can then
  # join in parallel.
  depends_on = [
    azurerm_windows_virtual_machine.machine,
    azurerm_virtual_machine_run_command.windows_dc,
  ]
}
