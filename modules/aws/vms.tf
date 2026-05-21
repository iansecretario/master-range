################################################################################
# Per-machine EC2 instances.
#
# Same role-fan-out as modules/azure/vms.tf — Linux roles render the
# matching userdata/*.sh and become aws_instance with cloud-init user_data;
# Windows roles render userdata/windows-*.ps1 and become aws_instance
# with `user_data` wrapped in <powershell>...</powershell> so EC2Launch v2
# executes it on first boot.
#
# The bootstrap-payload templatefile block is copied verbatim from the
# Azure module because:
#   - The userdata/*.{sh,ps1} scripts are provider-agnostic (cloud-init on
#     Linux, EC2Launch on Windows runs PowerShell identically).
#   - The variables they expect (linux_user, ssh_pubkey, domain_*,
#     winlogbeat_b64, persona_b64, …) are all defined in terraform locals,
#     not provider resources.
#   - Keeping one source-of-truth bootstrap block means a fix to a Kali
#     role in Azure automatically lands on AWS too.
#
# Roles fully supported on AWS:
#     attacker, c2-server, c2-mythic, c2-brc4, c2-sliver, c2-redirector,
#     windows-dc, windows-member, windows-workstation, linux-target
#
# Roles whose render template is supported but whose downstream wiring
# (CloudFront aliases, etc.) is Tier-2 work:
#     c2-redirector with fronts:<stack>  — works; CloudFront aliases
#     come up only when advanced_c2.enabled. Otherwise CHANGEME-* placeholders.
################################################################################

locals {
  # Bootstrap payload per machine. PORTED VERBATIM from modules/azure/vms.tf.
  # Any change here should be made in parallel in the Azure module so the
  # two stay in sync — or, better, refactor into a shared helper file.
  bootstrap = {
    for m in var.machines :
    m.name => (
      m.role == "windows-blank" ? templatefile("${path.module}/userdata/windows-blank.ps1", {
        local_admin    = m.win_admin_user
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
        fast_windows   = var.fast_windows ? "true" : "false"
        lab_users_json = jsonencode(var.domain.lab_users)
      }) :
      contains(["windows-member", "windows-workstation"], m.role) ? (
        m.persona_name != "" ? templatefile("${path.module}/userdata/windows-persona.ps1", {
          persona_b64    = m.persona_b64
          do_domain_join = m.domain_join
          domain_fqdn    = var.domain.fqdn
          domain_user    = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass    = local.effective_domain_password[m.student_id]
          dc_ip          = format("10.%d.0.10", m.student_index)
        }) : templatefile("${path.module}/userdata/windows-member.ps1", {
          local_admin     = m.win_admin_user
          local_password  = m.win_admin_password
          do_domain_join  = m.domain_join
          domain_fqdn     = var.domain.fqdn
          domain_user     = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass     = local.effective_domain_password[m.student_id]
          dc_ip           = format("10.%d.0.10", m.student_index)
          elk_endpoint    = "10.0.0.10"
          kibana_password = var.services.elk.kibana_password
          deploy_agents   = var.services.elk.deploy_agents
          student_id      = m.student_id
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
        listeners_json      = jsonencode(local.adaptix_listeners[m.student_id])
        redelk_ip           = ""  # shared infra deferred on AWS MVP
      }) :
      m.role == "c2-mythic" ? templatefile("${path.module}/userdata/c2-mythic.sh", {
        linux_user            = m.linux_user
        linux_pass            = m.linux_password
        ssh_pubkey            = local.effective_ssh_pubkey
        mythic_admin_password = local.effective_mythic_password[m.student_id]
        student_id            = m.student_id
        redelk_ip             = ""
      }) :
      m.role == "c2-brc4" ? templatefile("${path.module}/userdata/c2-brc4.sh", {
        linux_user          = m.linux_user
        linux_pass          = m.linux_password
        ssh_pubkey          = local.effective_ssh_pubkey
        brc4_license_id     = var.brc4_license_id
        brc4_activation_key = var.brc4_activation_key
        brc4_email          = var.brc4_email
        # brc4_blob_url is an Azure-only var (modules/azure/variables.tf).
        # On AWS we pass "" so the c2-brc4.sh script's "absent → skip
        # signed payload" branch fires. Operators who want the signed
        # payload can wire an S3 pre-signed URL through here later.
        brc4_blob_url       = ""
        student_id          = m.student_id
        student_index       = m.student_index
        brc4_profile_json   = local.brc4_profile[m.student_id]
        redelk_ip           = ""
      }) :
      m.role == "c2-sliver" ? templatefile("${path.module}/userdata/c2-sliver.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        ssh_pubkey      = local.effective_ssh_pubkey
        sliver_password = local.effective_sliver_password[m.student_id]
        student_id      = m.student_id
        student_index   = m.student_index
        redelk_ip       = ""
        cdn_headers_json = jsonencode([
          for cdn in local.cdn_names : {
            cdn    = cdn
            header = local.cdn_headers["sliver"][m.student_id][cdn].name
            value  = local.cdn_headers["sliver"][m.student_id][cdn].value
            port   = local.cdn_port[cdn]
          }
        ])
      }) :
      m.role == "c2-redirector" ? templatefile("${path.module}/userdata/c2-redirector.sh", {
        linux_user = m.linux_user
        linux_pass = m.linux_password
        ssh_pubkey = local.effective_ssh_pubkey
        student_id = m.student_id
        cover_url  = var.advanced_c2.cover_url
        redelk_ip  = ""
        upstream_host = (
          m.fronts == "c2-mythic" ? format("10.%d.1.7", m.student_index) :
          m.fronts == "c2-brc4"   ? format("10.%d.1.9", m.student_index) :
          m.fronts == "c2-sliver" ? format("10.%d.1.11", m.student_index) :
          format("10.%d.1.5", m.student_index)
        )
        cdn_headers = [
          for cdn in local.cdn_names : {
            cdn = cdn
            name = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4"   ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name
            header_var = lower(replace(local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4"   ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name, "-", "_"))
            value = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4"   ? "brc4" :
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
        root_password   = local.effective_domain_password[m.student_id]
      }) :
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

  # Per-machine static IP. Same convention as Azure: when the scenario
  # YAML specifies a static_ip, use it verbatim (already namespaced into
  # 10.<n>.0.<o> for targets or 10.<n>.1.<o> for attacker by the
  # generator). Empty string → DHCP (AWS picks a host from the subnet).
  machine_static_ip = {
    for m in var.machines :
    m.name => m.static_ip
  }

  # Conventionally pinned addresses by role. Mirrors Azure's
  # effective_static_ip map so the redirector/c2-* nodes are predictable
  # targets for inter-service config (e.g. listeners.tf hardcodes these).
  conventional_ip = {
    for m in var.machines :
    m.name => (
      m.static_ip != "" ? m.static_ip :
      m.role == "windows-dc"   ? format("10.%d.0.10", m.student_index) :
      m.role == "attacker"     ? format("10.%d.1.20", m.student_index) :
      m.role == "c2-server"    ? format("10.%d.1.5",  m.student_index) :
      m.role == "c2-mythic"    ? format("10.%d.1.7",  m.student_index) :
      m.role == "c2-brc4"      ? format("10.%d.1.9",  m.student_index) :
      m.role == "c2-sliver"    ? format("10.%d.1.11", m.student_index) :
      m.role == "c2-redirector"? format("10.%d.1.6",  m.student_index) :
      ""  # DHCP for ad-hoc roles (windows-member persona, linux-target, …)
    )
  }
}

# ============================================================================
# Linux instances
# ============================================================================
resource "aws_network_interface" "linux" {
  for_each = { for m in var.machines : m.name => m if local.is_linux[m.name] }

  subnet_id       = local.machine_subnet[each.key]
  private_ips     = local.conventional_ip[each.key] != "" ? [local.conventional_ip[each.key]] : null
  security_groups = [
    contains(local.target_roles, each.value.role)
    ? aws_security_group.student_targets[each.value.student_id].id
    : aws_security_group.student_attacker[each.value.student_id].id
  ]

  tags = {
    Name      = "${var.range_name}-${each.key}-nic"
    Range     = var.range_name
    StudentId = each.value.student_id
    Role      = each.value.role
  }
}

resource "aws_instance" "linux" {
  for_each = { for m in var.machines : m.name => m if local.is_linux[m.name] }

  ami           = local.image_ami_id[each.value.os]
  instance_type = lookup(local.size_map, each.value.size, "t3.medium")
  key_name      = aws_key_pair.operator.key_name

  network_interface {
    network_interface_id = aws_network_interface.linux[each.key].id
    device_index         = 0
  }

  user_data                   = local.bootstrap[each.key]
  user_data_replace_on_change = false  # cloud-init changes don't force replace

  root_block_device {
    volume_type = "gp3"
    volume_size = lookup(local.image_root_size, each.value.os, 30)
  }

  tags = {
    Name      = "${var.range_name}-${each.key}"
    Range     = var.range_name
    StudentId = each.value.student_id
    Role      = each.value.role
    OS        = each.value.os
  }

  lifecycle {
    # Mirror Azure: a userdata edit shouldn't force-replace a running VM.
    # ./range fix <vm> will re-run cloud-init in place via SSM.
    ignore_changes = [user_data, ami]
  }
}

# ============================================================================
# Windows instances
# ============================================================================
resource "aws_network_interface" "windows" {
  for_each = { for m in var.machines : m.name => m if local.is_windows[m.name] }

  subnet_id   = local.machine_subnet[each.key]
  private_ips = local.conventional_ip[each.key] != "" ? [local.conventional_ip[each.key]] : null
  security_groups = [
    contains(local.target_roles, each.value.role)
    ? aws_security_group.student_targets[each.value.student_id].id
    : aws_security_group.student_attacker[each.value.student_id].id
  ]

  tags = {
    Name      = "${var.range_name}-${each.key}-nic"
    Range     = var.range_name
    StudentId = each.value.student_id
    Role      = each.value.role
  }
}

resource "aws_instance" "windows" {
  for_each = { for m in var.machines : m.name => m if local.is_windows[m.name] }

  ami           = local.image_ami_id[each.value.os]
  instance_type = lookup(local.size_map, each.value.size, "t3.large")
  key_name      = aws_key_pair.operator.key_name

  network_interface {
    network_interface_id = aws_network_interface.windows[each.key].id
    device_index         = 0
  }

  # Windows user_data: wrap the PowerShell template in <powershell>…</powershell>
  # tags so EC2Launch v2 executes it on first boot. (EC2Launch also accepts
  # <persist>true</persist> for re-running on subsequent boots; we DON'T
  # set that — cloud-config / DC promotion is one-shot.)
  user_data                   = "<powershell>\n${local.bootstrap[each.key]}\n</powershell>"
  user_data_replace_on_change = false
  # Get the RDP password decryption to work — EC2 publishes the Windows
  # password only when get_password_data=true, then it's decryptable with
  # the operator's private key. Even though the scripts force a known
  # password later, this gives the initial console fallback.
  get_password_data = true

  root_block_device {
    volume_type = "gp3"
    volume_size = lookup(local.image_root_size, each.value.os, 128)
  }

  tags = {
    Name      = "${var.range_name}-${each.key}"
    Range     = var.range_name
    StudentId = each.value.student_id
    Role      = each.value.role
    OS        = each.value.os
  }

  lifecycle {
    ignore_changes = [user_data, ami, get_password_data]
  }
}
