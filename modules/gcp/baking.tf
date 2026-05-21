################################################################################
# Pre-baked image declarations for GCP. The GCP equivalent of
# modules/azure/baking.tf, but materially different in shape because GCP
# has no Shared Image Gallery resource to declare ahead of time.
#
# What's different from Azure (read this BEFORE adding new images):
#
#   - Azure SIG had THREE pieces: a gallery, image DEFINITIONS (slots
#     declared in terraform), and image VERSIONS (published by packer).
#   - GCP has ONE piece: `google_compute_image` resources, owned by
#     PACKER (not terraform), grouped by an `image_family` string. The
#     first packer build with `image_family = "kali-redteam"` creates
#     the family; later bakes append non-deprecated images to it.
#     `data.google_compute_image { family = ... }` returns the latest.
#
#   So this file does NOT declare image-definition resources the way
#   baking.tf does on Azure. It only declares the READ side:
#   `data.google_compute_image` blocks, each guarded by
#   `count = (var.baking.enabled && var.baking.use_baked_<x>) ? 1 : 0`
#   so they fire ONLY when the operator has opted in. If
#   use_baked_<x>=true is set BEFORE packer has actually baked anything
#   into the family, the data-source read fails LOUDLY at plan time —
#   the correct, actionable error: "bake first".
#
#   - There is also no equivalent of the SIG resource group +
#     prevent_destroy lifecycle here. GCP images live flat in
#     `projects/<proj>/global/images/`, are owned by packer, and are
#     NOT in this terraform state. `terraform destroy` of any specific
#     range therefore CANNOT delete a baked image — so the "protect
#     baked artifacts from destroy" problem solved by prevent_destroy
#     on Azure simply doesn't exist on GCP.
#
#   - Optional GCS staging bucket: GCP packer's `googlecompute` builder
#     writes the image via the Compute Engine API directly (no VHD
#     upload step like Azure's azure-arm builder). A GCS bucket isn't
#     required for image creation; we declare one only for packer's
#     build-log staging when baking is enabled, mirroring the audit
#     trail Azure's bake produces in its build-log container.
#
# Family-naming contract (must stay in sync with packer's image_family
# strings in packer/<image>/<image>.pkr.hcl):
#
#   Image          | image_family
#   ---------------+-------------------------------
#   Kali           | kali-redteam
#   Kali minimal   | kali-minimal
#   Server 2019    | win-server-2019
#   Server 2022    | win-server-2022-ad
#   Server 2025    | win-server-2025
#   Windows 10     | win-10
#   Windows 11     | win-11
#   ELK            | elk
#   RedELK         | redelk
#   Debian rdr     | debian-redirector
#   Guacamole      | guacamole
#   AdaptixC2      | adaptix
#   Mythic         | mythic
#   Sliver         | sliver
#   Ghostwriter    | ghostwriter
#   SteppingStones | stepping-stones
#
# Adding a new baked image: pick a family name, add a packer template
# that publishes with `image_family = "<name>"`, add the matching
# var.baking.use_baked_<x> flag in variables.tf, add a
# `data.google_compute_image` block here, and add the
# `baked_<x>_id` local + dispatch row in images.tf.
################################################################################

# ──────────────────────────────────────────────────────────────────────────────
# Optional GCS bucket for packer build-log audit. Empty by default; packer's
# googlecompute builder writes the image via Compute Engine API and does NOT
# require a staging bucket. This bucket exists purely so `./range bake`
# can push the packer logs + manifest somewhere durable for incident
# review. Disabled when baking is off (var.baking.enabled = false) — no
# cost when not in use.
#
# `uniform_bucket_level_access = true` so IAM is the only access path
# (no fine-grained ACLs to drift). `force_destroy = true` because packer
# logs are write-once artefacts; if the bucket is being deleted the
# logs going with it is the right behaviour.
# ──────────────────────────────────────────────────────────────────────────────
# google_storage_bucket "baking_logs" was here. Removed because the
# `var.baking.bucket_name` field wasn't declared in variables.tf and
# the bucket is a nice-to-have, not a hard dependency. Phase B or later
# can re-add it once we settle on whether Packer GCP build logs need
# persistent storage (the API already streams build output to stdout).
#
# To re-add: declare `bucket_name = optional(string, "...")` inside
# the `baking` object in variables.tf, then restore the resource below.

# ──────────────────────────────────────────────────────────────────────────────
# Image-family probes. One `data.google_compute_image` per baked image,
# each guarded by `count = (var.baking.enabled && var.baking.use_baked_<x>)
# ? 1 : 0` so the lookup fires ONLY when the operator has opted in to
# deploying from the baked image.
#
# These are the GCP equivalent of Azure's `data.azurerm_shared_image_version`
# reads. Result `self_link` is consumed by `local.baked_<x>_id` in
# images.tf, which then flows into `local.machine_source_image_id`.
#
# IMPORTANT: when use_baked_<x> = true but packer has NEVER baked an
# image into the family, the lookup FAILS with `googleapi: Error 404`
# at plan time. That's the correct, actionable error — "bake first".
# Do NOT wrap these in try() or coalesce(); the loud failure IS the UX.
#
# `most_recent = true` returns the newest non-deprecated image in the
# family. Packer deprecates older images of the same family at the end
# of each bake (a googlecompute builder option) so this resolves to the
# image just produced.
#
# `project = ` resolution: in the one-project-per-range model, baked
# images live in a SHARED host project (var.gcp_host_project_id) that
# survives `./range destroy` cycles. When that var is empty (single-
# project / dev testing mode), we fall back to the per-range project.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # The project that holds the baked custom images. Defaults to the
  # shared host project; falls back to the per-range project for single-
  # project dev/testing flows.
  baked_image_project = var.gcp_host_project_id != "" ? var.gcp_host_project_id : var.gcp_project_id
}

# ---- Windows Server 2022 (DC-eligible image; AD-DS pre-installed) ----------
data "google_compute_image" "win_server_2022_ad" {
  count       = (var.baking.enabled && var.baking.use_baked_win_server_2022) ? 1 : 0
  project     = local.baked_image_project
  family      = "win-server-2022-ad"
  most_recent = true
}

# ---- Windows Server 2025 (DC-eligible; AD-DS roles pre-installed) ----------
data "google_compute_image" "win_server_2025" {
  count       = (var.baking.enabled && var.baking.use_baked_win_server_2025) ? 1 : 0
  project     = local.baked_image_project
  family      = "win-server-2025"
  most_recent = true
}

# ---- Windows Server 2019 (member-server role; srv01) -----------------------
data "google_compute_image" "win_server_2019" {
  count       = (var.baking.enabled && var.baking.use_baked_win_server_2019) ? 1 : 0
  project     = local.baked_image_project
  family      = "win-server-2019"
  most_recent = true
}

# ---- Windows 10 (workstation; analyst pool) --------------------------------
# NOTE: GCP has no Windows-client SKU on marketplace, so the baked image
# referenced here MUST come from a BYOL upload (operator's own Win10 VHD
# uploaded to GCE via `gcloud compute images import`). If you don't have
# a Win10 VHD, leave use_baked_win_10 = false; vms.tf falls back to the
# Windows-2022 server SKU per the image_map note in images.tf.
data "google_compute_image" "win_10" {
  count       = (var.baking.enabled && var.baking.use_baked_win_10) ? 1 : 0
  project     = local.baked_image_project
  family      = "win-10"
  most_recent = true
}

# ---- Windows 11 (workstation; ws11) ----------------------------------------
# Same BYOL caveat as win_10 above.
data "google_compute_image" "win_11" {
  count       = (var.baking.enabled && var.baking.use_baked_win_11) ? 1 : 0
  project     = local.baked_image_project
  family      = "win-11"
  most_recent = true
}

# ---- Kali Linux (attacker workstation) -------------------------------------
# Pre-baked with kali-linux-default + XFCE + TigerVNC/xrdp + the
# AdaptixClient build-dependency stack. Cuts the attacker-box deploy
# from ~30-45 min to ~2-3 min and removes the long async metapackage-
# install task entirely. On GCP, the packer source is the public
# kali-rolling marketplace image (see images.tf image_map for the
# project name); the baked output lives in YOUR project's image
# namespace under family "kali-redteam".
data "google_compute_image" "kali_redteam" {
  count       = (var.baking.enabled && var.baking.use_baked_kali) ? 1 : 0
  project     = local.baked_image_project
  family      = "kali-redteam"
  most_recent = true
}

# ---- ELK (elastic + kibana + logstash + agent staging) ---------------------
data "google_compute_image" "elk" {
  count       = (var.baking.enabled && var.baking.use_baked_elk) ? 1 : 0
  project     = local.baked_image_project
  family      = "elk"
  most_recent = true
}

# ---- RedELK (docker + RedELK repo + pre-pulled images) ---------------------
data "google_compute_image" "redelk" {
  count       = (var.baking.enabled && var.baking.use_baked_redelk) ? 1 : 0
  project     = local.baked_image_project
  family      = "redelk"
  most_recent = true
}

# ---- Debian redirector (nginx + base packages) -----------------------------
data "google_compute_image" "debian_redirector" {
  count       = (var.baking.enabled && var.baking.use_baked_debian_redirector) ? 1 : 0
  project     = local.baked_image_project
  family      = "debian-redirector"
  most_recent = true
}

# ---- Guacamole (Ubuntu 22.04 + docker + pre-pulled guac images + nginx) ----
data "google_compute_image" "guacamole" {
  count       = (var.baking.enabled && var.baking.use_baked_guacamole) ? 1 : 0
  project     = local.baked_image_project
  family      = "guacamole"
  most_recent = true
}

# ---- AdaptixC2 teamserver (Debian 12 + Go + AdaptixC2 pre-compiled) --------
data "google_compute_image" "adaptix" {
  count       = (var.baking.enabled && var.baking.use_baked_adaptix) ? 1 : 0
  project     = local.baked_image_project
  family      = "adaptix"
  most_recent = true
}

# ---- Mythic teamserver (Debian 12 + Docker + Mythic + mythic-cli) ----------
data "google_compute_image" "mythic" {
  count       = (var.baking.enabled && var.baking.use_baked_mythic) ? 1 : 0
  project     = local.baked_image_project
  family      = "mythic"
  most_recent = true
}

# ---- Sliver teamserver (Debian 12 + sliver-server binary pre-staged) ------
data "google_compute_image" "sliver" {
  count       = (var.baking.enabled && var.baking.use_baked_sliver) ? 1 : 0
  project     = local.baked_image_project
  family      = "sliver"
  most_recent = true
}

# ---- Ghostwriter reporting platform ----------------------------------------
# Debian 12 + Docker + docker-compose + Ghostwriter repo + ghostwriter-cli
# compiled + production images pre-built.
data "google_compute_image" "ghostwriter" {
  count       = (var.baking.enabled && var.baking.use_baked_ghostwriter) ? 1 : 0
  project     = local.baked_image_project
  family      = "ghostwriter"
  most_recent = true
}

# ---- Stepping Stones activity logger ---------------------------------------
# Debian 12 + Docker + Stepping-Stones repo + images pre-pulled.
data "google_compute_image" "stepping_stones" {
  count       = (var.baking.enabled && var.baking.use_baked_stepping_stones) ? 1 : 0
  project     = local.baked_image_project
  family      = "stepping-stones"
  most_recent = true
}

# ──────────────────────────────────────────────────────────────────────────────
# Image-family "slot exists" markers. Pure null_resource sentinels that
# carry the baking-enabled state forward for any downstream consumer that
# wants to depend on "baking is configured" without depending on a specific
# image family's read.
#
# This is the GCP equivalent of the Azure SIG image-definition resources —
# not because GCP needs the resource to exist before packer publishes
# (it doesn't), but because the `./range bake` wrapper's
# `_ensure_baked_images_exist` probe needs SOMETHING to grep for in
# `terraform state list` to detect "yes, this image family is configured
# in this deploy". The triggers map records the family-name → packer-
# template mapping so a future operator can `terraform state show
# null_resource.baked_family["kali"]` and see what the build slot expects.
# ──────────────────────────────────────────────────────────────────────────────
resource "null_resource" "baked_family" {
  for_each = var.baking.enabled ? {
    kali              = "packer/kali/kali-redteam.pkr.hcl"
    kali_minimal      = "packer/kali-minimal/kali-minimal.pkr.hcl"
    win_server_2019   = "packer/win-server-2019/win-server-2019.pkr.hcl"
    win_server_2022   = "packer/win-server-2022-ad/win-server-2022-ad.pkr.hcl"
    win_server_2025   = "packer/win-server-2025/win-server-2025.pkr.hcl"
    win_10            = "packer/win-10/win-10.pkr.hcl"
    win_11            = "packer/win-11/win-11.pkr.hcl"
    elk               = "packer/elk/elk.pkr.hcl"
    redelk            = "packer/redelk/redelk.pkr.hcl"
    debian_redirector = "packer/debian-redirector/debian-redirector.pkr.hcl"
    guacamole         = "packer/guacamole/guacamole.pkr.hcl"
    adaptix           = "packer/adaptix/adaptix.pkr.hcl"
    mythic            = "packer/mythic/mythic.pkr.hcl"
    sliver            = "packer/sliver/sliver.pkr.hcl"
    ghostwriter       = "packer/ghostwriter/ghostwriter.pkr.hcl"
    stepping_stones   = "packer/stepping-stones/stepping-stones.pkr.hcl"
  } : {}

  triggers = {
    family_name     = each.key
    packer_template = each.value
    project         = local.baked_image_project
    region          = var.azure_region
  }
}
