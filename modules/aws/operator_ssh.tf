################################################################################
# Operator SSH keypair.
#
# When the scenario YAML's services.adaptix.ssh_pubkey is left blank or
# at the placeholder default ("ssh-ed25519 AAAA... operator@you"), we
# generate a fresh ed25519 keypair and:
#   - plant the public key on every Linux VM via cloud-init users:
#   - drop the private key into labs/<range_name>/operator-id_ed25519
#     (mode 0600) for the operator to use locally
#
# When the scenario does pass a real public key, the generator output
# flows it into local.effective_ssh_pubkey instead (see locals.tf) and
# this resource is still created — but the private key file points to
# a key that won't open most VMs. That's the operator's call.
################################################################################

resource "tls_private_key" "operator" {
  algorithm = "ED25519"
  lifecycle {
    ignore_changes = [algorithm]
  }
}

locals {
  lab_dir = "${path.root}/../../labs/${var.range_name}"
}

resource "local_sensitive_file" "operator_private_key" {
  filename        = "${local.lab_dir}/operator-id_ed25519"
  content         = tls_private_key.operator.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "operator_public_key" {
  filename        = "${local.lab_dir}/operator-id_ed25519.pub"
  content         = tls_private_key.operator.public_key_openssh
  file_permission = "0644"
}

# Imported into AWS so EC2 instances can opt in via key_name without
# having to template the public key into every cloud-init file (cloud-init
# users: still gets the key — this is for SSH troubleshooting and for
# the rare resources that want key_name directly).
resource "aws_key_pair" "operator" {
  key_name   = "${var.range_name}-operator"
  public_key = local.effective_ssh_pubkey
}
