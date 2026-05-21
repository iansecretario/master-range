################################################################################
# Operator SSH keypair for ALL Linux boxes in the range. PORTED FROM
# modules/azure/operator_ssh.tf with the same fallback semantics.
#
# Until now scenarios had to embed an ssh-ed25519 public key into the YAML
# via `services.adaptix.ssh_pubkey`. That's awkward (key-rotation in YAML,
# accidental commits of personal keys) and the placeholder
# "ssh-ed25519 AAAA... operator@you" is invalid PEM, so cloud-init silently
# dropped it and operators couldn't SSH in at all.
#
# We now generate a fresh ed25519 keypair per deploy:
#   - tls_private_key.operator regenerates only if the resource is
#     destroyed and recreated; ignore_changes on the algorithm field keeps
#     re-applies idempotent (same key across applies, no operator lockout).
#   - The PUBLIC key is wired into every cloud-init `ssh_authorized_keys`
#     stanza via local.effective_ssh_pubkey, AND planted as instance
#     metadata `ssh-keys = "ranger:<pubkey>"` on every google_compute_instance
#     so OS-Login-disabled boxes (which is all of them — see vms.tf for the
#     `enable-oslogin = FALSE` rationale) honor the operator's SSH login.
#   - The PRIVATE key is written to envs/gcp/operator-id_ed25519 (well,
#     labs/<range_name>/operator-id_ed25519 — see path resolution below)
#     with mode 0600 so operators can `ssh -i ...` immediately.
#
# GCP-specific notes:
#   - GCP's default authentication path is OS Login (cloud-side
#     IAM-bound usernames + short-lived certs). OS Login is INCOMPATIBLE
#     with cloud-init's ad-hoc `users:` stanza — when OS Login is on,
#     `useradd ranger` works but cloud-side OS-Login then refuses to
#     authenticate that local user because IAM doesn't know about it.
#     We disable OS Login on every instance (see vms.tf metadata block)
#     and plant the operator key in instance metadata under the SAME
#     username (`ranger`) that cloud-init creates locally.
#   - Format of the instance-metadata ssh-keys value is
#     `<username>:<full-ssh-keystring>` separated by newlines for multiple
#     keys. We construct that string here for downstream consumption.
#
# Operator can still override by setting services.adaptix.ssh_pubkey to
# their own pubkey in YAML; we detect the "...operator@you" placeholder
# (and any other clearly invalid value) and substitute the auto-key.
################################################################################

resource "tls_private_key" "operator" {
  algorithm = "ED25519"

  lifecycle {
    # Match AWS module behavior: don't rotate just because someone messed
    # with the algorithm field. Rotation only when the resource is
    # explicitly tainted / destroyed.
    ignore_changes = [algorithm]
  }
}

# Per-deploy artifacts live in <repo>/labs/<range_name>/ — that way:
#   - multiple ranges can coexist on the same machine without their
#     keys/credentials stepping on each other
#   - `./range destroy` only has to `rm -rf labs/<range_name>` to fully
#     forget a deploy (alongside `terraform destroy`)
#   - operators can grep `cat labs/<range_name>/credentials.txt` for
#     everything they need, instead of `terraform output -json | jq`
#
# path.root is envs/gcp, so labs/ resolves to ../../labs at the repo root.
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
  _yaml_pubkey = trimspace(var.services.adaptix.ssh_pubkey)
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

  # Instance-metadata `ssh-keys` value. Format is `<user>:<full-key>`
  # newline-separated. We plant the SAME operator pubkey under the
  # `ranger` username that cloud-init creates locally on every Linux
  # box. Some scenarios may want a second key planted (e.g. an
  # instructor's separate troubleshooting key) — add another line here:
  #   "instructor:ssh-ed25519 AAAA..."
  # The list-of-strings → newline-join shape preserves that future
  # extensibility without changing the call sites in vms.tf.
  ssh_keys_metadata = join("\n", [
    "ranger:${local.effective_ssh_pubkey}",
  ])
}
