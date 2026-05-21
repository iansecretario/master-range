################################################################################
# Operator SSH keypair for ALL Linux boxes in the range.
#
# Until now scenarios had to embed an ssh-ed25519 public key into the
# YAML via `services.adaptix.ssh_pubkey`. That's awkward (key-rotation
# in YAML, accidental commits of personal keys) and the placeholder
# "ssh-ed25519 AAAA... operator@you" is invalid PEM, so cloud-init
# silently dropped it and operators couldn't ssh in at all.
#
# We now generate a fresh ed25519 keypair per deploy:
#   - terraform_data forces regeneration only when the range name
#     changes (so re-applying the same range doesn't rotate keys
#     and lock you out of running VMs)
#   - The PUBLIC key is wired into every cloud-init `ssh_authorized_keys`
#     stanza via local.effective_ssh_pubkey
#   - The PRIVATE key is written to envs/azure/operator-id_ed25519
#     with mode 0600 so operators can `ssh -i ...` immediately
#
# Operator can still override by setting services.adaptix.ssh_pubkey to
# their own pubkey in YAML; we detect the "...operator@you" placeholder
# (and any other clearly invalid value) and substitute the auto-key.
################################################################################

resource "tls_private_key" "operator" {
  algorithm = "ED25519"
}

# Per-deploy artifacts live in <repo>/labs/<range_name>/ — that way:
#   - multiple ranges can coexist on the same machine without their
#     keys/credentials stepping on each other
#   - `./range destroy` only has to `rm -rf labs/<range_name>` to fully
#     forget a deploy (alongside `terraform destroy`)
#   - operators can grep `cat labs/<range_name>/credentials.txt` for
#     everything they need, instead of `terraform output -json | jq`
#
# path.root is envs/azure, so labs/ resolves to ../../labs at the repo root.
locals {
  lab_dir = "${path.root}/../../labs/${var.range_name}"
}

resource "local_sensitive_file" "operator_private_key" {
  content         = tls_private_key.operator.private_key_openssh
  filename        = "${local.lab_dir}/operator-id_ed25519"
  file_permission = "0600"
}

resource "local_file" "operator_public_key" {
  content         = tls_private_key.operator.public_key_openssh
  filename        = "${local.lab_dir}/operator-id_ed25519.pub"
  file_permission = "0644"
}

locals {
  # Detect placeholder / empty values in the scenario YAML and substitute
  # our auto-generated key. Anything that doesn't look like a real
  # ssh-* key gets the generated one. The check is conservative — any
  # value starting with "ssh-rsa", "ssh-ed25519", "ssh-ecdsa", or
  # "ssh-dss" that has more than 64 chars passes through unchanged.
  _yaml_pubkey  = trimspace(var.services.adaptix.ssh_pubkey)
  _yaml_looks_real_pubkey = (
    can(regex("^ssh-(rsa|ed25519|ecdsa|dss)\\s+[A-Za-z0-9+/=]{64,}", local._yaml_pubkey))
    && !can(regex("AAAA\\.\\.\\.", local._yaml_pubkey)) # the "AAAA..." placeholder
    && !can(regex("operator@you", local._yaml_pubkey))
  )
  effective_ssh_pubkey = (
    local._yaml_looks_real_pubkey
    ? local._yaml_pubkey
    : trimspace(tls_private_key.operator.public_key_openssh)
  )
}
