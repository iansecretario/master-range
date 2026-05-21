################################################################################
# Shared locals + role classification.
#
# Mirrors modules/azure/vms.tf's locals so the rest of the AWS module reads
# the same way as the Azure one when an operator hops between them.
################################################################################

locals {
  # Distinct student IDs in this deploy. When the scenario uses
  # `students.count > 1` each ID is "student-NN"; for single-student
  # deploys (the common path) the only ID is "" and per-student loops
  # iterate exactly once.
  students = distinct([for m in var.machines : m.student_id])

  # Quick role lookups — same predicate sets as Azure.
  is_windows = {
    for m in var.machines : m.name => startswith(m.os, "windows")
  }
  is_linux = {
    for m in var.machines : m.name => !startswith(m.os, "windows")
  }

  # Per-machine subnet routing. Same allocation rule as Azure:
  #   - target roles  (windows-*, linux-target)  → student VPC "targets"  subnet
  #   - attacker roles (kali, c2-*)              → student VPC "attacker" subnet
  target_roles   = ["windows-dc", "windows-member", "windows-workstation", "linux-target"]
  attacker_roles = ["attacker", "c2-server", "c2-redirector", "c2-mythic", "c2-sliver", "c2-brc4"]

  machine_subnet = {
    for m in var.machines : m.name => (
      contains(local.target_roles, m.role)
      ? aws_subnet.student_targets[m.student_id].id
      : aws_subnet.student_attacker[m.student_id].id
    )
  }

  # Per-student CIDR plan, MATCHING the Azure module exactly:
  #   - Hub VPC          10.0.0.0/22
  #   - Student <n> VPC  10.<n>.0.0/22       where n = student_index (starts at 1)
  #   - targets subnet   10.<n>.0.0/24
  #   - attacker subnet  10.<n>.1.0/24
  # Single-student deploys still get student_index=1 from the generator,
  # so the math is identical there.
  student_vpc_index = {
    for m in var.machines : m.student_id => m.student_index...
  }
  student_vpc_cidr = {
    for sid, idxs in local.student_vpc_index :
    sid => "10.${idxs[0]}.0.0/22"
  }
  student_targets_cidr = {
    for sid, idxs in local.student_vpc_index :
    sid => "10.${idxs[0]}.0.0/24"
  }
  student_attacker_cidr = {
    for sid, idxs in local.student_vpc_index :
    sid => "10.${idxs[0]}.1.0/24"
  }

  # Domain-admin password per student. AWS uses the same random_password
  # resource as Azure (see passwords.tf); this is the lookup-map shape
  # that the rest of the module reads from.
  effective_domain_password = {
    for sid in local.students :
    sid => random_password.domain_admin[sid].result
  }

  # Guacamole admin password resolution (same logic as Azure).
  _is_weak_guac_pw = contains(
    ["", "Lab!Guac1", "guacamole", "admin", "password"],
    var.services.guacamole.admin_password
  )
  effective_guacamole_admin_password = (
    local._is_weak_guac_pw
    ? random_password.guacamole_admin.result
    : var.services.guacamole.admin_password
  )

  # Effective SSH pubkey. Either the operator's value from
  # services.adaptix.ssh_pubkey or the auto-generated one in
  # operator_ssh.tf (when the operator left it as a placeholder).
  _ssh_pubkey_raw       = var.services.adaptix.ssh_pubkey
  _ssh_pubkey_is_placeholder = (
    var.services.adaptix.ssh_pubkey == "" ||
    can(regex("^ssh-ed25519 AAAA\\.\\.\\.", var.services.adaptix.ssh_pubkey))
  )
  effective_ssh_pubkey = (
    local._ssh_pubkey_is_placeholder
    ? tls_private_key.operator.public_key_openssh
    : local._ssh_pubkey_raw
  )

  # Guacamole effective FQDN. Either the custom hostname under the
  # operator's Route 53 zone, or — if neither is set — the public IP
  # of the Guacamole instance (no LE cert, falls back to self-signed).
  guac_custom_enabled = (
    var.services.guacamole.dns_zone_name  != "" &&
    var.services.guacamole.custom_hostname != ""
  )
  guac_effective_fqdn = (
    local.guac_custom_enabled
    ? "${var.services.guacamole.custom_hostname}.${var.services.guacamole.dns_zone_name}"
    : (length(aws_eip.guacamole) > 0 ? aws_eip.guacamole[0].public_ip : "")
  )
}
