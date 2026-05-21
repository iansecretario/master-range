################################################################################
# Firewall rules: tag-driven, per-VPC. Mirrors the Azure NSG rules in
# modules/azure/hub.tf and modules/azure/students.tf, but adapted to
# GCP's per-VPC firewall model.
#
# How GCP firewalls differ from Azure NSGs:
#   - Azure NSGs are PER-SUBNET. GCP firewall rules are PER-VPC and
#     scoped by tags (`target_tags`) or service accounts. A rule
#     applies to every VM in the VPC carrying the listed tag.
#   - Azure priorities are 100..4096. GCP priorities are 0..65535 with
#     an implicit "default deny ingress, default allow egress" at 65535.
#   - Azure NSGs accept up to 4000 source prefixes per rule (we cap at
#     1900 for safety). **GCP firewall rules cap at 256 source ranges
#     per rule.** This is the single biggest network-config delta — see
#     `chunklist(local.effective_ingress_cidrs, 256)` below.
#
# Rule cap (READ THIS BEFORE ADDING RULES):
#   GCP default cap is ~100 firewall rules per VPC. Raise to 500 via
#   `gcloud compute project-info describe --project=<id>` then a quota
#   bump request for `Firewalls`. With a 4300-CIDR geofence chunked to
#   256-CIDR slices, the operator-ingress rules alone consume ~17 rules
#   per logical purpose × 3 purposes = ~50 rules. The C2 stack tag-based
#   rules add ~30 more. Multi-student deploys >5 students will hit the
#   100 cap and need the quota bump.
################################################################################

locals {
  # ─── Geofence chunking ───────────────────────────────────────────────────
  # GCP firewall rules cap at 256 source ranges per rule. We slice the
  # operator geofence into 250-CIDR chunks (256 minus a small headroom
  # in case Terraform emits a trailing entry the provider rejects) and
  # render one google_compute_firewall per chunk. Priority numbering
  # reserves blocks 1000..1099 (https), 1100..1199 (ssh), 1200..1299
  # (kibana) — supporting up to 100 chunks each (≈ 25k CIDRs).
  _fw_cidr_chunk_size = 250

  # Defense-in-depth cap matching the Azure side. With 250-CIDR chunks
  # and a 100-chunk block per logical purpose, the absolute ceiling is
  # 25000 CIDRs; we cap at 24000 to keep a safety margin before the
  # priority block overflows into the next reserved range.
  _fw_cidr_cap = 24000
  effective_ingress_cidrs = slice(
    var.guacamole_ingress_cidrs,
    0,
    min(local._fw_cidr_cap, length(var.guacamole_ingress_cidrs))
  )

  # Hub CIDRs as a flat list — used by `allow-hub-to-spoke-*` rules so
  # any VM tagged `hub` (mgmt, infra, or shared-lab) is treated as the
  # operator's control plane.
  hub_cidrs = [
    var.hub_mgmt_cidr,
    var.hub_infra_cidr,
    var.hub_shared_lab_cidr,
  ]

  # Google IAP TCP forwarder range. Operators tunneling SSH/RDP via
  # `gcloud compute start-iap-tunnel` always source from this /20.
  # Documented at https://cloud.google.com/iap/docs/using-tcp-forwarding
  iap_source_range = "35.235.240.0/20"

  # Google health-check probers. Required if we ever attach LB backend
  # services to internal VMs (cdn.tf will use this); harmless to allow
  # on hub-infra ahead of time so we don't churn this rule later.
  google_health_check_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}

################################################################################
# 1. allow-iap-ssh — operators tunneling SSH (22) / RDP (3389) via IAP.
#    Targets `allow-iap` tag — set this tag on any VM you want to
#    reach via `gcloud compute start-iap-tunnel <vm> 22 ...`.
################################################################################

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.range_name}-allow-iap-ssh"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Operator IAP TCP-forwarder ingress for SSH (22), RDP (3389), and WinRM (5985/5986)."
  direction   = "INGRESS"
  priority    = 900

  source_ranges = [local.iap_source_range]
  target_tags   = ["allow-iap"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389", "5985", "5986"]
  }
}

################################################################################
# 2. allow-guac-ingress — operator geofence → Guacamole (22/80/443).
#    Chunked at 250 CIDRs/rule (the GCP per-rule source-range cap).
#    Targets `guacamole` tag.
################################################################################

resource "google_compute_firewall" "allow_guac_ingress" {
  for_each = {
    for idx, chunk in chunklist(local.effective_ingress_cidrs, local._fw_cidr_chunk_size) :
    tostring(idx) => chunk
  }

  name    = "${var.range_name}-allow-guac-ingress-${each.key}"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Operator ingress to Guacamole on 22/80/443 (chunk ${each.key} of ${length(chunklist(local.effective_ingress_cidrs, local._fw_cidr_chunk_size))})."
  direction   = "INGRESS"
  priority    = 1000 + tonumber(each.key)

  source_ranges = each.value
  target_tags   = ["guacamole"]

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"]
  }
}

################################################################################
# 3. allow-operator-hub-ingress — operator geofence → hub-infra web UIs
#    (Ghostwriter, SteppingStones, RedELK, Kibana). Same chunking
#    pattern as Guacamole. Targets `hub-infra` tag.
################################################################################

resource "google_compute_firewall" "allow_operator_hub_web" {
  for_each = {
    for idx, chunk in chunklist(local.effective_ingress_cidrs, local._fw_cidr_chunk_size) :
    tostring(idx) => chunk
  }

  name    = "${var.range_name}-allow-operator-hub-web-${each.key}"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Operator ingress to hub-infra web UIs (Kibana 5601, Ghostwriter 8000, etc.)."
  direction   = "INGRESS"
  priority    = 1200 + tonumber(each.key)

  source_ranges = each.value
  target_tags   = ["hub-infra"]

  allow {
    protocol = "tcp"
    ports    = ["22", "443", "5601", "8000", "8080"]
  }
}

# Let's Encrypt HTTP-01 challenge on :80. Open to the world so ACME
# validators from any LE region can reach the Guacamole VM. Renewal
# runs every ~60 days. nginx redirects everything except
# /.well-known/acme-challenge/* to HTTPS so this is harmless.
resource "google_compute_firewall" "allow_acme_http" {
  name    = "${var.range_name}-allow-acme-http"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Let's Encrypt HTTP-01 challenge on :80 to Guacamole (world-readable; nginx redirects to HTTPS for all other paths)."
  direction   = "INGRESS"
  priority    = 1500

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["guacamole"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

################################################################################
# 4. allow-east-west-hub — anything tagged `hub` can talk to anything
#    else tagged `hub` on any port. Mirrors Azure's hub-mgmt + hub-infra
#    "intra-vnet allow".
################################################################################

resource "google_compute_firewall" "allow_east_west_hub" {
  name    = "${var.range_name}-allow-east-west-hub"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Intra-hub east/west: any hub-tagged VM can reach any other hub-tagged VM on any port."
  direction   = "INGRESS"
  priority    = 2000

  source_tags = ["hub"]
  target_tags = ["hub"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# Logs flow into hub-infra (RedELK on 5044/9200/5601) from anywhere in
# the VPC — student C2 teamservers and redirectors ship logs here via
# Filebeat. CIDR-based (not tag-based) so any VM in the 10/8 range can
# reach RedELK without needing a special tag.
resource "google_compute_firewall" "allow_logs_to_hub_infra" {
  name    = "${var.range_name}-allow-logs-to-hub-infra"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Filebeat/Winlogbeat from anywhere in 10/8 → RedELK on hub-infra."
  direction   = "INGRESS"
  priority    = 2100

  source_ranges = ["10.0.0.0/8"]
  target_tags   = ["hub-infra"]

  allow {
    protocol = "tcp"
    ports    = ["5044", "9200", "5601"]
  }
}

# Google health-check probers (used by Cloud LB backends). Allowed
# pre-emptively to hub-infra and guacamole so cdn.tf can wire backend
# services later without re-churning firewall rules. No-op if no LB
# is attached.
resource "google_compute_firewall" "allow_google_health_checks" {
  name    = "${var.range_name}-allow-google-health-checks"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "GCP managed health-check probers (LB backends)."
  direction   = "INGRESS"
  priority    = 2200

  source_ranges = local.google_health_check_ranges
  target_tags   = ["lb-backend"]

  allow { protocol = "tcp" }
}

################################################################################
# 5. allow-east-west-spoke — per-student intra-spoke. Uses
#    student-specific source/target tags so student-01 can't reach
#    student-02 even though they share a VPC.
################################################################################

resource "google_compute_firewall" "allow_east_west_spoke" {
  for_each = toset(local.per_student_spokes)

  name    = "${var.range_name}-allow-east-west-${local.student_meta[each.key].tag}"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Intra-spoke east/west for student ${local.student_meta[each.key].tag}: tag-scoped so other students cannot cross into this spoke."
  direction   = "INGRESS"
  priority    = 3000

  # CIDR-bounded so the rule rejects packets sourced from a tagged VM
  # in a DIFFERENT student's subnet. (GCP firewall semantics: when both
  # source_ranges and source_tags are set, source_ranges is an AND
  # constraint, so this gives us proper cross-student isolation.)
  source_ranges = [local.student_meta[each.key].cidr]
  target_tags   = ["student-${local.student_meta[each.key].tag}"]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

################################################################################
# 6. allow-hub-to-spoke-rdp-ssh — Guacamole + hub-infra need RDP/SSH
#    into every student spoke for the pivot. WinRM 5985/5986 added so
#    Ansible can reach Windows boxes during build.
################################################################################

resource "google_compute_firewall" "allow_hub_to_spoke" {
  name    = "${var.range_name}-allow-hub-to-spoke"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Hub (Guacamole, hub-infra) → student VMs for RDP/SSH/WinRM during build + operator pivot."
  direction   = "INGRESS"
  priority    = 3100

  source_ranges = local.hub_cidrs
  target_tags   = ["student-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22", "3389", "5985", "5986"]
  }
}

################################################################################
# 7. allow-hub-to-c2-listeners — Guacamole + Kali (which lives in
#    hub-infra) can reach the per-student C2 teamservers on their
#    commander/operator ports. Listener ports (8443-8447) are scoped
#    by separate rules below.
#
#    NOTE: in the Azure side, the C2 commander rules are deliberately
#    narrowed to kali-only by IP. The GCP analog uses tags — only VMs
#    tagged `kali` (which only the kali workspace VM has) can reach
#    `c2-server`. Other hub VMs hit the implicit deny.
################################################################################

resource "google_compute_firewall" "allow_kali_to_c2_commander" {
  name    = "${var.range_name}-allow-kali-to-c2-commander"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Kali operator workspace → C2 teamserver commander/operator ports (Adaptix 9000, Mythic 7443, BRC4 9000, Sliver 31337)."
  direction   = "INGRESS"
  priority    = 3200

  source_tags = ["kali"]
  target_tags = [
    "c2-server", # generic catch-all
    "c2-adaptix",
    "c2-mythic",
    "c2-brc4",
    "c2-sliver",
  ]

  allow {
    protocol = "tcp"
    ports    = ["7443", "9000", "31337"]
  }
}

# Redirector → listener pairs. Each C2 framework gets one rule so a
# rogue redirector (e.g. the Adaptix redirector hitting Mythic's
# teamserver) gets implicit-denied. Source tag is per-C2-redirector;
# target tag is per-C2-listener.
resource "google_compute_firewall" "allow_redir_to_listener_adaptix" {
  name    = "${var.range_name}-allow-redir-adaptix-to-listener"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Adaptix redirector → Adaptix listener ports (8443-8447 HTTPS, 8448-8449 GopherTCP, 53 DNS, 80 HTTP-bare-fallback)."
  direction   = "INGRESS"
  priority    = 3300

  source_tags = ["c2-redirector-adaptix"]
  target_tags = ["c2-adaptix"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "53", "8443-8449"]
  }
  allow {
    protocol = "udp"
    ports    = ["53"]
  }
}

resource "google_compute_firewall" "allow_redir_to_listener_mythic" {
  name    = "${var.range_name}-allow-redir-mythic-to-listener"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Mythic redirector → Mythic listener ports."
  direction   = "INGRESS"
  priority    = 3301

  source_tags = ["c2-redirector-mythic"]
  target_tags = ["c2-mythic"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8443-8447"]
  }
}

resource "google_compute_firewall" "allow_redir_to_listener_brc4" {
  name    = "${var.range_name}-allow-redir-brc4-to-listener"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "BRC4 redirector → BRC4 listener ports."
  direction   = "INGRESS"
  priority    = 3302

  source_tags = ["c2-redirector-brc4"]
  target_tags = ["c2-brc4"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8443-8447"]
  }
}

resource "google_compute_firewall" "allow_redir_to_listener_sliver" {
  name    = "${var.range_name}-allow-redir-sliver-to-listener"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Sliver redirector → Sliver listener ports (incl. DoH→raw-DNS leg on UDP 5353)."
  direction   = "INGRESS"
  priority    = 3303

  source_tags = ["c2-redirector-sliver"]
  target_tags = ["c2-sliver"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8443-8447"]
  }
  allow {
    protocol = "udp"
    ports    = ["5353"]
  }
}

################################################################################
# 8. allow-internet-to-redirector — public ingress to every C2
#    redirector on 80/443. The redirector's nginx layer-7 logic
#    validates the per-deploy `beacon_header_token` and either
#    forwards to the upstream teamserver or 302s to `cover_url`.
#
#    This is the GCP analog of Azure's `azurerm_cdn_frontdoor` +
#    `AzureFrontDoor.Backend` NSG rule. See GCP_PARITY_ROADMAP.md §5:
#    GCP has no "Cloud CDN backend" service tag, so we accept 0.0.0.0/0
#    and rely on nginx header validation (operator's
#    `beacon_header_token`) — the same security model as Azure's
#    `fdid_header_required = true`.
################################################################################

resource "google_compute_firewall" "allow_internet_to_redirector" {
  name    = "${var.range_name}-allow-internet-to-redirector"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Public ingress to C2 redirectors on 80/443. nginx header validation is the security boundary (operator beacon_header_token + fdid_header_required)."
  direction   = "INGRESS"
  priority    = 4000

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["c2-redirector"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

################################################################################
# 9. deny-cross-student — explicit cross-spoke deny. A VM in
#    student-01 cannot initiate traffic into student-02. This is
#    defense-in-depth alongside the tag-scoped allow rules above:
#    even if a tag is misapplied (e.g. someone adds `student-02-vm`
#    to a student-01 VM by mistake), this rule blocks the spoke→spoke
#    path at the CIDR level.
#
#    Only emitted when there are >= 2 per-student spokes.
################################################################################

resource "google_compute_firewall" "deny_cross_student" {
  count = length(local.per_student_spokes) >= 2 ? 1 : 0

  name    = "${var.range_name}-deny-cross-student"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Defense-in-depth: deny any spoke CIDR → any spoke CIDR. Hub→spoke + intra-spoke remain allowed via the rules above (which have lower priority numbers = higher precedence)."
  direction   = "INGRESS"
  priority    = 5000

  source_ranges      = local.all_spoke_cidrs
  destination_ranges = local.all_spoke_cidrs
  target_tags        = ["student-vm"]

  deny { protocol = "all" }
}

################################################################################
# 10. lockdown egress — when var.lockdown == true, deny ALL egress to
#     the internet for student VMs. Internal traffic (10/8) stays
#     allowed via the implicit "default allow egress" being overridden
#     only for the 0.0.0.0/0 target.
#
#     GCP-specific subtlety: GCP's default egress is ALLOW-ALL. To
#     match Azure's lockdown semantics (deny internet, allow intra-VPC)
#     we emit an egress deny for 0.0.0.0/0 + an egress allow for
#     10.0.0.0/8 at a lower priority number (higher precedence).
################################################################################

resource "google_compute_firewall" "lockdown_allow_internal_egress" {
  count = var.lockdown ? 1 : 0

  name    = "${var.range_name}-lockdown-allow-internal-egress"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Lockdown: allow egress to 10/8 (intra-VPC). Paired with the deny-internet-egress rule below."
  direction   = "EGRESS"
  priority    = 6000

  destination_ranges = ["10.0.0.0/8"]
  target_tags        = ["student-vm"]

  allow { protocol = "all" }
}

resource "google_compute_firewall" "lockdown_deny_internet_egress" {
  count = var.lockdown ? 1 : 0

  name    = "${var.range_name}-lockdown-deny-internet-egress"
  project = var.gcp_project_id
  network = google_compute_network.hub.name

  description = "Lockdown: deny egress to the public internet for student VMs. Re-apply with var.lockdown=false to restore."
  direction   = "EGRESS"
  priority    = 6100

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["student-vm"]

  deny { protocol = "all" }
}
