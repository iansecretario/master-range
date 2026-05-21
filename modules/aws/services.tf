################################################################################
# Hub services on AWS — Guacamole (operator entry point) + ELK + the
# Guacamole connection manifest builder.
#
# Same `guac_connections` shape as Azure so userdata/guacamole.sh's
# register.py reads identically. The IP that goes into each entry is the
# private IP of the matching aws_network_interface.
################################################################################

locals {
  _lab_user_pwd = { for u in var.domain.lab_users : u.name => u.password }

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
  }] : []

  guac_connections = concat(
    # 1. Base per-machine entry. Linux + Windows + role-aware protocol.
    [
      for m in var.machines : {
        name       = m.name
        base_name  = m.base_name
        student_id = m.student_id
        role       = m.role
        os         = m.os
        hostname   = local.is_linux[m.name] ? aws_network_interface.linux[m.name].private_ip : aws_network_interface.windows[m.name].private_ip
        protocol = (
          local.is_windows[m.name] ? "rdp" :
          m.role == "attacker"     ? "vnc" :
          "ssh"
        )
        username = local.is_windows[m.name] ? m.win_admin_user : m.linux_user
        password = local.is_windows[m.name] ? local.effective_domain_password[m.student_id] : m.linux_password
        port = (
          local.is_windows[m.name] ? 3389 :
          m.role == "attacker"     ? 5901 :
          22
        )
        domain_join = m.domain_join
      }
    ],
    # 2. Extra Windows RDP-as-domain-user (regular user tier).
    [
      for m in var.machines : {
        name        = "${m.name} (${m.assigned_user}@${var.domain.netbios})"
        base_name   = m.base_name
        student_id  = m.student_id
        role        = m.role
        os          = m.os
        hostname    = aws_network_interface.windows[m.name].private_ip
        protocol    = "rdp"
        username    = "${var.domain.netbios}\\${m.assigned_user}"
        password    = lookup(local._lab_user_pwd, m.assigned_user, "")
        port        = 3389
        domain_join = m.domain_join
      }
      if local.is_windows[m.name] && m.assigned_user != "" && contains(keys(local._lab_user_pwd), m.assigned_user)
    ],
    # 3. Extra Linux SSH-as-root.
    [
      for m in var.machines : {
        name        = "${m.name} (root)"
        base_name   = m.base_name
        student_id  = m.student_id
        role        = m.role
        os          = m.os
        hostname    = aws_network_interface.linux[m.name].private_ip
        protocol    = "ssh"
        username    = "root"
        password    = local.effective_domain_password[m.student_id]
        port        = 22
        domain_join = false
      }
      if !local.is_windows[m.name] && m.enable_root_ssh
    ],
    # 4. Shared infra (currently empty on AWS — see shared_infra.tf comments).
    [],
    # 5. ELK
    local._elk_guac_entry,
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

# ============================================================================
# ELK instance
# ============================================================================
resource "aws_eip" "elk" {
  count  = var.services.elk.enabled && var.services.elk.public_ip ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.range_name}-elk-eip", Range = var.range_name }
}

resource "aws_network_interface" "elk" {
  count           = var.services.elk.enabled ? 1 : 0
  subnet_id       = aws_subnet.hub_mgmt.id
  private_ips     = ["10.0.0.10"]
  security_groups = [aws_security_group.hub_mgmt.id]
  tags            = { Name = "${var.range_name}-elk-nic", Range = var.range_name }
}

resource "aws_eip_association" "elk" {
  count                = var.services.elk.enabled && var.services.elk.public_ip ? 1 : 0
  network_interface_id = aws_network_interface.elk[0].id
  allocation_id        = aws_eip.elk[0].id
}

resource "aws_instance" "elk" {
  count         = var.services.elk.enabled ? 1 : 0
  ami           = data.aws_ami.ubuntu_22.id
  instance_type = "t3.xlarge"  # 4 vCPU / 16 GB — ELK is memory-hungry
  key_name      = aws_key_pair.operator.key_name

  network_interface {
    network_interface_id = aws_network_interface.elk[0].id
    device_index         = 0
  }

  user_data = templatefile("${path.module}/userdata/elk.sh", {
    kibana_user     = var.services.elk.kibana_user
    kibana_password = var.services.elk.kibana_password
  })
  user_data_replace_on_change = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
  }

  tags = { Name = "${var.range_name}-elk", Range = var.range_name, Tier = "hub", Service = "elk" }

  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

# ============================================================================
# Guacamole instance
# ============================================================================
resource "aws_eip" "guacamole" {
  count  = var.services.guacamole.enabled ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.range_name}-guac-eip", Range = var.range_name }
}

resource "aws_network_interface" "guacamole" {
  count           = var.services.guacamole.enabled ? 1 : 0
  subnet_id       = aws_subnet.hub_mgmt.id
  private_ips     = ["10.0.0.20"]
  security_groups = [aws_security_group.hub_mgmt.id]
  tags            = { Name = "${var.range_name}-guac-nic", Range = var.range_name }
}

resource "aws_eip_association" "guacamole" {
  count                = var.services.guacamole.enabled ? 1 : 0
  network_interface_id = aws_network_interface.guacamole[0].id
  allocation_id        = aws_eip.guacamole[0].id
}

resource "aws_instance" "guacamole" {
  count         = var.services.guacamole.enabled ? 1 : 0
  ami           = data.aws_ami.ubuntu_22.id
  instance_type = "t3.medium"
  key_name      = aws_key_pair.operator.key_name

  network_interface {
    network_interface_id = aws_network_interface.guacamole[0].id
    device_index         = 0
  }

  user_data = templatefile("${path.module}/userdata/guacamole.sh", {
    admin_user      = var.services.guacamole.admin_user
    admin_password  = local.effective_guacamole_admin_password
    manifest_b64    = base64encode(local.guac_manifest)
    guac_fqdn       = local.guac_effective_fqdn
    guac_acme_email = var.services.guacamole.acme_email
    ssh_pubkey      = local.effective_ssh_pubkey
    # The Azure userdata's wildcard-cert / Key Vault plumbing reads these
    # values. On AWS we pass empty strings so the HTTP-01 fallback path
    # runs (per-FQDN cert). Tier-2 work: wire Secrets Manager + ACM here.
    guac_wildcard_zone     = ""
    guac_wildcard_zone_rg  = ""
    guac_wildcard_zone_sub = ""
    guac_kv_name           = ""
  })
  user_data_replace_on_change = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
  }

  tags = { Name = "${var.range_name}-guac", Range = var.range_name, Tier = "hub", Service = "guacamole" }

  depends_on = [
    aws_network_interface.linux,
    aws_network_interface.windows,
  ]

  lifecycle {
    ignore_changes = [user_data, ami]
  }
}
