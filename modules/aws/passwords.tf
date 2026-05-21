################################################################################
# Per-student randomized credentials. Identical shape to
# modules/azure/passwords.tf (deliberate — register.py reads the same
# manifest keys in both clouds). The override_special sets are tuned for
# Guacamole connection-param safety + protocol-loader safety.
################################################################################

resource "random_password" "domain_admin" {
  for_each         = toset(local.students)
  length           = 24
  upper            = true
  lower            = true
  numeric          = true
  special          = true
  override_special = "!#$%&*()-_=+"
  lifecycle {
    ignore_changes = [length, upper, lower, numeric, special, override_special]
  }
}

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

locals {
  effective_adaptix_password = {
    for sid in local.students :
    sid => random_password.adaptix[sid].result
  }
  effective_mythic_password = {
    for sid in local.students :
    sid => random_password.mythic[sid].result
  }
  effective_brc4_password = {
    for sid in local.students :
    sid => random_password.brc4[sid].result
  }
  effective_sliver_password = {
    for sid in local.students :
    sid => random_password.sliver[sid].result
  }
}

# ---- "ian" operator passwords -----------------------------------------
# Match Azure's shape: each C2 (Adaptix, Mythic) gets a second operator
# beyond the teamserver admin. Sliver uses cert auth, not a password.
resource "random_password" "operator_ian_adaptix" {
  length           = 24
  upper            = true
  lower            = true
  numeric          = true
  special          = true
  override_special = "!@#$%^&*-_+="
}
resource "random_password" "operator_ian_mythic" {
  length           = 24
  upper            = true
  lower            = true
  numeric          = true
  special          = true
  override_special = "!@#%^&*-_+="
}

locals {
  operator_ian = {
    username         = "ian"
    adaptix_password = random_password.operator_ian_adaptix.result
    mythic_password  = random_password.operator_ian_mythic.result
  }
}

# ============================================================================
# CDN headers + ports (cloud-agnostic — same shape as Azure passwords.tf).
# The c2-server, c2-redirector, c2-sliver, c2-brc4 userdata all read from
# local.cdn_headers / local.cdn_port. With CloudFront fronting (AWS),
# the upstream port still keys off the matched X-Api-* header just like
# AFD; the only difference is which edge CDN routes which header.
# ============================================================================
locals {
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

  adaptix_enc_pairs = flatten([
    for sid in local.students : [
      for cdn in local.cdn_names : { student = sid, cdn = cdn }
    ]
  ])

  cdn_port = {
    azure      = 8443
    cloudfront = 8444
    workers    = 8445
    fastly     = 8446
    other      = 8447
  }
}

resource "random_shuffle" "api_header_suffixes" {
  for_each     = { for p in local.student_stack_pairs : "${p.student}-${p.stack}" => p }
  input        = local.api_header_pool
  result_count = 5
  lifecycle {
    ignore_changes = [input, result_count]
  }
}

resource "random_uuid" "api_header_value" {
  for_each = { for p in local.cdn_listener_pairs : "${p.student}-${p.stack}-${p.cdn}" => p }
}

resource "random_id" "adaptix_enc_key" {
  for_each    = { for p in local.adaptix_enc_pairs : "${p.student}-${p.cdn}" => p }
  byte_length = 16
}

locals {
  adaptix_listener_enc_keys = {
    for sid in local.students :
    sid => {
      for cdn in local.cdn_names :
      cdn => random_id.adaptix_enc_key["${sid}-${cdn}"].hex
    }
  }

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
}
