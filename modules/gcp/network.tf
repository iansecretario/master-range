################################################################################
# Network: one shared VPC for hub + every student spoke, all subnets carved
# out of the same 10.0.0.0/8 supernet that the Azure side uses.
#
# Why one VPC (not "one VPC per student + peering")?
#   - GCP firewall rules are PER-VPC and TAG-BASED. A single VPC with
#     per-student network tags (e.g. `student-01`, `student-02`) gives
#     cross-student isolation with one set of allow rules instead of
#     N(N-1) peerings. The roadmap (`docs/GCP_PARITY_ROADMAP.md` §2 +
#     §5) calls this out as the recommended Phase B shape.
#   - GCP VPCs are GLOBAL; subnets are REGIONAL. terra-range only
#     deploys to one region per range, so the "global VPC" property
#     doesn't matter — we still chunk subnets the same way Azure carves
#     spokes.
#   - `terraform destroy` of a single student doesn't tear down the
#     hub (the per-student resources are keyed by student_id with
#     `for_each` so removing a student from `var.machines` removes
#     just that student's subnet + NAT + tags).
#
# CIDR plan (mirrors the Azure side):
#   hub                  10.0.0.0/22
#     hub-mgmt           10.0.0.0/24
#     hub-infra          10.0.1.0/24
#     hub-shared-lab     10.0.2.0/24
#   student-<n>          10.<n>.0.0/22
#     student-<n>-target   10.<n>.0.0/24
#     student-<n>-attacker 10.<n>.1.0/24
#
# Where <n> = student_index from var.machines (1..254). Index 0 is
# reserved for the hub.
################################################################################

locals {
  # All distinct student ids — INCLUDES the "" id used by per_student=false
  # (shared) machines in multi-student shared-mode deploys. Same logic as
  # modules/azure/students.tf so the two providers stay in lockstep.
  students = distinct([for m in var.machines : m.student_id])

  multi_student_shared = (
    contains(local.students, "")
    && length(local.students) > 1
  )

  # Subset of `students` that get per-student NETWORK resources. The ""
  # id is filtered out in multi-student-shared mode (those machines live
  # in the hub's shared-lab subnet).
  per_student_spokes = (
    local.multi_student_shared
    ? [for sid in local.students : sid if sid != ""]
    : local.students
  )

  # student_id -> { index, cidr, targets_cidr, attacker_cidr, tag }
  # `tag` is the GCP network tag that scopes per-student firewall rules.
  # Sanitised so it survives GCP's name rules (lowercase, [-a-z0-9]+).
  student_meta = {
    for sid in local.per_student_spokes :
    sid => {
      index         = [for m in var.machines : m.student_index if m.student_id == sid][0]
      cidr          = format("10.%d.0.0/22", [for m in var.machines : m.student_index if m.student_id == sid][0])
      targets_cidr  = format("10.%d.0.0/24", [for m in var.machines : m.student_index if m.student_id == sid][0])
      attacker_cidr = format("10.%d.1.0/24", [for m in var.machines : m.student_index if m.student_id == sid][0])
      # Sanitised student tag — strips any underscores/uppercase that
      # would slip past GCP's [a-z]([-a-z0-9]*[a-z0-9])? tag regex.
      # Empty student_id (single-student mode) becomes the literal
      # "single" so the tag is still a valid identifier.
      tag = sid == "" ? "single" : lower(replace(sid, "_", "-"))
    }
  }

  # Flat list of per-student CIDRs — used by firewall.tf for the
  # cross-student deny rule and the hub→spoke allow rule.
  all_spoke_cidrs = [for sid in local.per_student_spokes : local.student_meta[sid].cidr]
}

################################################################################
# Hub VPC (the only VPC). Custom subnet mode — we declare every subnet
# explicitly. Auto-mode would pre-create one subnet per region in the
# 10.128.0.0/9 range, which collides with our 10.0.0.0/8 plan.
################################################################################

resource "google_compute_network" "hub" {
  name                            = "${var.range_name}-vpc"
  project                         = var.gcp_project_id
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
  mtu                             = 1460

  description = "${var.range_name} — shared VPC for hub + all student spokes"
}

################################################################################
# Hub subnets (mgmt / infra / shared-lab). Regional in var.azure_region
# (despite the name, this var is already set to a GCP region string in
# variables.tf — `asia-southeast1` by default).
################################################################################

resource "google_compute_subnetwork" "hub_mgmt" {
  name          = "${var.range_name}-hub-mgmt"
  project       = var.gcp_project_id
  region        = var.azure_region
  network       = google_compute_network.hub.id
  ip_cidr_range = var.hub_mgmt_cidr

  # Lets VMs without external IPs reach Google APIs (Marketplace agent,
  # Cloud Monitoring, Cloud Logging, Cloud Storage for state). Without
  # this an internal-only VM cannot pull from gcr.io or write logs.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "hub_infra" {
  name                     = "${var.range_name}-hub-infra"
  project                  = var.gcp_project_id
  region                   = var.azure_region
  network                  = google_compute_network.hub.id
  ip_cidr_range            = var.hub_infra_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Shared-lab subnet — home for per_student=false target machines in
# multi-student `shared` mode. Empty (no instances) in single-student
# deploys; cost is zero (GCP doesn't bill for empty subnets, only for
# instances/forwarding-rules attached to them).
resource "google_compute_subnetwork" "hub_shared_lab" {
  name                     = "${var.range_name}-hub-shared-lab"
  project                  = var.gcp_project_id
  region                   = var.azure_region
  network                  = google_compute_network.hub.id
  ip_cidr_range            = var.hub_shared_lab_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

################################################################################
# Per-student subnets (target + attacker). Same /24 carving as Azure.
# Subnets are keyed by student_id so add/remove a student is a clean
# `terraform apply`.
################################################################################

resource "google_compute_subnetwork" "student_target" {
  for_each = toset(local.per_student_spokes)

  name                     = "${var.range_name}-${local.student_meta[each.key].tag}-target"
  project                  = var.gcp_project_id
  region                   = var.azure_region
  network                  = google_compute_network.hub.id
  ip_cidr_range            = local.student_meta[each.key].targets_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_subnetwork" "student_attacker" {
  for_each = toset(local.per_student_spokes)

  name                     = "${var.range_name}-${local.student_meta[each.key].tag}-attacker"
  project                  = var.gcp_project_id
  region                   = var.azure_region
  network                  = google_compute_network.hub.id
  ip_cidr_range            = local.student_meta[each.key].attacker_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

################################################################################
# Note on VPC peering: we deliberately DO NOT create
# `google_compute_network_peering` resources here. Because every subnet
# lives in the same VPC (`google_compute_network.hub`), GCP's implicit
# intra-VPC route already covers hub<->spoke and spoke<->spoke traffic.
# Firewall rules in firewall.tf are the only thing controlling who can
# talk to whom — cross-student isolation is enforced by `target_tags`
# matching the per-student tag, NOT by routing.
#
# If a future caller needs hard routing isolation (Shared VPC host
# project + service projects, or one VPC per student), that's a larger
# refactor — see GCP_PARITY_ROADMAP.md §1 + §5 for the trade-offs.
################################################################################
