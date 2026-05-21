################################################################################
# Per-student randomized credentials. PORTED FROM modules/azure/passwords.tf.
#
# These resources are PROVIDER-AGNOSTIC: the `hashicorp/random` provider is
# the same across Azure, AWS, and GCP. The only thing different about this
# file vs. the Azure one is the file-level comment (this) acknowledging
# that this is the GCP copy, plus the spot_pinned_roles local mirrors the
# Azure value so the GCP vms.tf can pin windows-dc and c2-redirector to
# Regular even when var.vm_priority == "Spot" globally.
#
# Each student gets:
#   - a unique Domain Admin password
#   - a unique teamserver password per C2 framework (Adaptix, Mythic, BRC4,
#     Sliver)
#   - a per-CDN (X-Api-<RandomName>, UUID) pair per C2 framework. Five CDNs
#     per stack: azure, cloudfront, workers, fastly, other. The redirector's
#     nginx maps each header → upstream port (8443/8444/8445/8446/8447).
#
# All four C2 frameworks are per-student. BRC4 license caps the range at
# one teamserver activation, so c2-brc4 scenarios always run with
# `students.count: 1` (enforced in generate.py).
################################################################################

# ---- Domain Admin ----------------------------------------------------------

resource "random_password" "domain_admin" {
  # NOTE: override_special applies to the entire family of random_password
  # resources below (adaptix, mythic, brc4, sliver, guacamole_admin) — we
  # restrict to the same RDP/SSH-safe set everywhere so Guacamole's
  # connection params don't trip on URL-or-protocol-special chars like
  # ':', '?', '/', '<', '>', '"' that the default set includes.
  #
  # On GCP the same character-class concern applies — the Windows password
  # we set via the `windows-startup-script-ps1` metadata key is rendered
  # into a PowerShell `net user … /add` line, which has the same parser
  # quirks as Azure's RunCommand source.
  #
  # (Each resource still declares its own override_special below; this
  # comment documents the policy.)
  for_each = toset(local.students)
  length   = 24
  upper    = true
  lower    = true
  numeric  = true
  special  = true
  # Avoid characters that break PowerShell here-strings, JSON encoding,
  # or `net user` credential parsing.
  override_special = "!#$%&*()-_=+"

  # Re-running terraform apply must not regenerate (would force-recreate
  # every Windows VM). Lifecycle keeps the same password across applies.
  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special, override_special]
  }
}

# ---- Per-C2 teamserver passwords -------------------------------------------

# Adaptix teamserver / operator password — alphanum-only to stay safe with
# the upstream profile YAML loader.
resource "random_password" "adaptix" {
  for_each = toset(local.students)
  length   = 24
  upper    = true
  lower    = true
  numeric  = true
  special  = false

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special]
  }
}

# Mythic admin password — the .env loader does basic shell-style expansion,
# so avoid $ ` " characters.
resource "random_password" "mythic" {
  for_each         = toset(local.students)
  length           = 24
  upper            = true
  lower            = true
  numeric          = true
  special          = true
  override_special = "!#%&*()-_=+"

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special, override_special]
  }
}

# BRC4 teamserver password — alphanum-only; BRC4 first-run setup is strict
# about credential format.
resource "random_password" "brc4" {
  for_each = toset(local.students)
  length   = 24
  upper    = true
  lower    = true
  numeric  = true
  special  = false

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special]
  }
}

# BRC4 automation operator password — used by the brc4_payload Ansible
# role to drive the BRC4 WebSocket API (task 36 build, task 8 listeners,
# task 31 profiles, etc.). Distinct from the admin password so the
# operator's Commander GUI session and the playbook's API session run
# concurrently as separate operator identities and don't kick each other
# off the shared :9000 endpoint.
#
# Plumbed through listeners.tf (`brc4_profile.user_list.automation`),
# outputs.tf (ansible_inventory hosts entry + brc4_connections), and
# inventory.py (`terra_brc4_automation_password` hostvar).
resource "random_password" "brc4_automation" {
  for_each = toset(local.students)
  length   = 24
  upper    = true
  lower    = true
  numeric  = true
  special  = false

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special]
  }
}

# Sliver operator password — drives the multiplayer config-file generation
# seed. Alphanum-only; sliver-server's `new-operator` embeds it into the
# .cfg JSON.
resource "random_password" "sliver" {
  for_each = toset(local.students)
  length   = 24
  upper    = true
  lower    = true
  numeric  = true
  special  = false

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special]
  }
}

# Guacamole admin password. Scenarios used to ship a hardcoded
# "Lab!Guac1" default which is trivially brute-forceable. We now generate
# a strong per-deploy random by default; the scenario can still pin a
# specific value via services.guacamole.admin_password (anything other
# than empty / the legacy "Lab!Guac1" default wins).
resource "random_password" "guacamole_admin" {
  length           = 28
  upper            = true
  lower            = true
  numeric          = true
  special          = true
  override_special = "!#%&*()-_=+"

  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special, override_special]
  }
}

# ---- Adaptix listener encryption keys (one per student × CDN) --------------
#
# beacon_listener_http's TransportConfig.encrypt_key is a 32-hex-char RC4
# key. We generate one per (student, CDN) so each listener instance has
# distinct keying material.

locals {
  adaptix_enc_pairs = flatten([
    for sid in local.students : [
      for cdn in local.cdn_names : { student = sid, cdn = cdn }
    ]
  ])
}

resource "random_id" "adaptix_enc_key" {
  for_each    = { for p in local.adaptix_enc_pairs : "${p.student}-${p.cdn}" => p }
  byte_length = 16
}

# ---- Per-CDN X-Api header (name + UUID) per C2 stack -----------------------
#
# One (header_name, header_value) per (student, stack, CDN). Header names
# drawn from a 20-name pool; the 5 CDNs per (student, stack) get distinct
# suffixes so there are no nginx-level collisions.

locals {
  # CDN names are kept identical to Azure even though "azure" reads oddly
  # in a GCP-fronted deploy. The string here just keys per-CDN listener
  # configs — the actual front-end provider is dispatched in cdn.tf
  # (Cloud CDN / Cloud Front-Door equivalent / WAF rules) by the parallel
  # agent. Renaming the keys would break listener cross-references in
  # listeners.tf and the outputs map.
  cdn_names = ["azure", "cloudfront", "workers", "fastly", "other"]
  c2_stacks = ["adaptix", "mythic", "brc4", "sliver"]
  api_header_pool = [
    "Auth", "Token", "Session", "Key", "Sig", "Trace", "Request",
    "Client", "Cdn", "Edge", "Origin", "Tier", "Region", "Stage",
    "Build", "Channel", "Profile", "Variant", "Stream", "Frame",
  ]

  student_stack_pairs = flatten([
    for sid in local.students : [
      for stack in local.c2_stacks : { student = sid, stack = stack }
    ]
  ])

  cdn_listener_pairs = flatten([
    for sid in local.students : [
      for stack in local.c2_stacks : [
        for cdn in local.cdn_names : {
          student = sid, stack = stack, cdn = cdn
        }
      ]
    ]
  ])
}

# 5 distinct header-name suffixes per (student, stack).
resource "random_shuffle" "api_header_suffixes" {
  for_each     = { for p in local.student_stack_pairs : "${p.student}-${p.stack}" => p }
  input        = local.api_header_pool
  result_count = 5

  lifecycle {
    ignore_changes = [input, result_count]
  }
}

# UUID per (student, stack, CDN).
resource "random_uuid" "api_header_value" {
  for_each = { for p in local.cdn_listener_pairs : "${p.student}-${p.stack}-${p.cdn}" => p }
}

# ---- "ian" operator passwords (extra user beyond the teamserver admin) ----
# Each C2 gets a SECOND operator account named `ian` with its own random
# password. Sliver uses cert-based gRPC auth (no password) — for sliver
# we just generate an operator.cfg at /opt/sliver-cfg/ian.cfg.
#
# Adaptix uses YAML operators: { name: password } map → password gets
# splatted into profile.yaml.
#
# Mythic uses its REST API (POST /api/v1.4/operators) authenticated as
# admin; the role POSTs a create-operator request with this password.
resource "random_password" "operator_ian_adaptix" {
  length  = 24
  upper   = true
  lower   = true
  numeric = true
  special = true
  # YAML-safe: no single/double quotes, no colon, no whitespace —
  # profile.yaml renders this between double quotes.
  override_special = "!@#$%^&*-_+="
}

resource "random_password" "operator_ian_mythic" {
  length  = 24
  upper   = true
  lower   = true
  numeric = true
  special = true
  # JSON-safe: no backslash, no quotes; Mythic's POST /operators body is
  # JSON. Defense against shell-escaping in the role's URI module.
  override_special = "!@#%^&*-_+="
}

locals {
  effective_domain_password = {
    for sid in local.students :
    sid => random_password.domain_admin[sid].result
  }

  effective_adaptix_password = {
    for sid in local.students :
    sid => random_password.adaptix[sid].result
  }

  effective_mythic_password = {
    for sid in local.students :
    sid => random_password.mythic[sid].result
  }

  # "ian" operator passwords — same value for every student (single random
  # per C2, not per-student). If you need per-student ian accounts, make
  # these for_each = toset(local.students) like the others.
  operator_ian = {
    username         = "ian"
    adaptix_password = random_password.operator_ian_adaptix.result
    mythic_password  = random_password.operator_ian_mythic.result
  }

  effective_brc4_password = {
    for sid in local.students :
    sid => random_password.brc4[sid].result
  }

  # See `random_password.brc4_automation` above for why this exists
  # alongside the admin password.
  effective_brc4_automation_password = {
    for sid in local.students :
    sid => random_password.brc4_automation[sid].result
  }

  effective_sliver_password = {
    for sid in local.students :
    sid => random_password.sliver[sid].result
  }

  # Guacamole admin password resolution:
  #   - Empty string -> generated 28-char random
  #   - Legacy "Lab!Guac1" (and other obviously weak defaults) -> generated random
  #   - Anything else -> operator's value wins
  # Surfaced via the `guacamole_admin_password` output and `./range creds`.
  _is_weak_guac_pw = contains(
    ["", "Lab!Guac1", "guacamole", "admin", "password"],
    var.services.guacamole.admin_password
  )
  effective_guacamole_admin_password = (
    local._is_weak_guac_pw
    ? random_password.guacamole_admin.result
    : var.services.guacamole.admin_password
  )

  # Per-student per-listener RC4 keys: { sid => { cdn => "<32-hex>" } }
  adaptix_listener_enc_keys = {
    for sid in local.students :
    sid => {
      for cdn in local.cdn_names :
      cdn => random_id.adaptix_enc_key["${sid}-${cdn}"].hex
    }
  }

  # CDN port assignment is fixed across all stacks.
  cdn_port = {
    azure      = 8443
    cloudfront = 8444
    workers    = 8445
    fastly     = 8446
    other      = 8447
  }

  # Per-stack header table:
  #   { stack => { sid => { cdn => { name, value, port } } } }
  cdn_headers = {
    for stack in local.c2_stacks :
    stack => {
      for sid in local.students :
      sid => {
        for idx, cdn in local.cdn_names :
        cdn => {
          name  = "X-Api-${random_shuffle.api_header_suffixes["${sid}-${stack}"].result[idx]}"
          value = random_uuid.api_header_value["${sid}-${stack}-${cdn}"].result
          port  = local.cdn_port[cdn]
        }
      }
    }
  }

  # Critical-infrastructure roles that stay Regular priority even when
  # --spot is set globally (var.vm_priority == "Spot"). Eviction of any
  # of these mid-bootstrap or mid-validation breaks the range:
  #
  #   - windows-dc      → mid-promotion eviction = corrupt forest;
  #                       AD cannot recover from partial state. On GCP a
  #                       SPOT preemption sends a 30-second ACPI shutdown
  #                       signal (same as Azure's Deallocate-on-eviction),
  #                       which is NOT enough time for AD's NTDS commits
  #                       to flush mid-promotion.
  #   - c2-redirector   → eviction during managed-cert / CDN provisioning
  #                       leaves the custom domain in a half-validated
  #                       state; requires terraform taint + reapply.
  #
  # Identical list to modules/azure/images.tf's local.spot_pinned_roles —
  # mirrored here in passwords.tf on GCP because images.tf is owned by a
  # parallel agent and we don't want to introduce a write-ordering
  # dependency between the two agents. vms.tf reads
  # `local.spot_pinned_roles` from THIS file.
  spot_pinned_roles = ["windows-dc", "c2-redirector"]
}
