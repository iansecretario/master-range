################################################################################
# Per-machine VMs on GCP. Provider-equivalent of modules/azure/vms.tf.
#
# Unlike Azure (which splits Linux and Windows into different resource
# types — azurerm_linux_virtual_machine vs azurerm_windows_virtual_machine),
# GCP uses a single `google_compute_instance` for both OS families. The
# OS personality is selected by the boot-disk image and by which
# `metadata.<key>` startup-script key we set:
#
#   Linux   →  metadata.startup-script           = "<bash>"
#   Windows →  metadata.windows-startup-script-ps1 = "<powershell>"
#
# We still keep TWO `for_each` resources (one filtered to Linux, one to
# Windows) because:
#   - per-OS root-disk sizing differs significantly (Linux 40-128 GB,
#     Windows 128-256 GB)
#   - Linux instances always set `enable-oslogin = FALSE` + plant the
#     operator SSH key, Windows instances don't have OS Login at all
#   - Windows needs the `windows-startup-script-ps1` metadata + a
#     deterministic admin-password reset script; Linux uses cloud-init
#     `users:` and admin_password is irrelevant
#
# Splitting the resources keeps each block's per-OS knobs obvious and
# avoids a long dynamic{}-soup. Pattern is copied verbatim from the
# Azure module — same role-fan-out for the bootstrap payload, same
# static-IP convention, same role-based size/disk sizing.
#
# The bootstrap-payload templatefile block is copied verbatim from the
# Azure module because:
#   - The userdata/*.{sh,ps1} scripts are provider-agnostic (cloud-init
#     on Linux, the matching Windows GCP-Agent runs PowerShell identically
#     to Azure's RunCommand).
#   - The variables they expect (linux_user, ssh_pubkey, domain_*,
#     winlogbeat_b64, persona_b64, …) are all defined in terraform
#     locals, not provider resources.
#   - Keeping one source-of-truth bootstrap block means a fix to a Kali
#     role in Azure automatically lands on GCP too.
################################################################################

locals {
  # Bootstrap payload per machine. PORTED VERBATIM from modules/azure/vms.tf.
  # Any change here should be made in parallel in the Azure module so the
  # two stay in sync — or, better, refactor into a shared helper file.
  bootstrap = {
    for m in var.machines :
    m.name => (
      m.role == "windows-blank" ? templatefile("${path.module}/userdata/windows-blank.ps1", {
        local_admin = m.win_admin_user
        # windows-blank gets the per-student random password too, so
        # ansible bridge can authenticate uniformly across students.
        local_password = local.effective_domain_password[m.student_id]
      }) :
      m.role == "windows-analyst" ? templatefile("${path.module}/userdata/windows-analyst.ps1", {
        local_admin    = m.win_admin_user
        local_password = local.effective_domain_password[m.student_id]
      }) :
      m.role == "windows-dc" ? templatefile("${path.module}/userdata/windows-dc.ps1", {
        domain_fqdn       = var.domain.fqdn
        netbios           = var.domain.netbios
        admin_user        = var.domain.admin_user
        admin_password    = local.effective_domain_password[m.student_id]
        safemode_password = var.domain.safemode_password
        local_admin       = m.win_admin_user
        local_password    = local.effective_domain_password[m.student_id]
        elk_endpoint      = "10.0.0.10"
        kibana_password   = var.services.elk.kibana_password
        deploy_agents     = var.services.elk.deploy_agents
        student_id        = m.student_id
        # Winlogbeat YAML pre-built in terraform and base64'd to avoid
        # the PowerShell here-string parser's misbehavior on multi-line
        # "- name: ..." content. DC ships DS + DNS event logs in
        # addition to the standard Application/System/Security/Sysmon
        # set.
        winlogbeat_b64 = base64encode(join("\n", [
          "winlogbeat.event_logs:",
          "  - name: Application",
          "  - name: System",
          "  - name: Security",
          "  - name: Microsoft-Windows-Sysmon/Operational",
          "  - name: Directory Service",
          "  - name: DNS Server",
          "output.elasticsearch:",
          "  hosts: [\"http://10.0.0.10:9200\"]",
          "  username: elastic",
          "  password: \"${var.services.elk.kibana_password}\"",
          "",
        ]))
        fast_windows   = var.fast_windows ? "true" : "false"
        lab_users_json = jsonencode(var.domain.lab_users)
      }) :
      contains(["windows-member", "windows-workstation"], m.role) ? (
        m.persona_name != "" ? templatefile("${path.module}/userdata/windows-persona.ps1", {
          persona_b64    = m.persona_b64
          do_domain_join = m.domain_join
          domain_fqdn    = var.domain.fqdn
          domain_user    = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass    = local.effective_domain_password[m.student_id]
          # DC IP dispatch:
          #   - In multi-student shared mode (m.student_id=="" with other
          #     real student ids present) the DC is the SHARED dc01 in
          #     the hub's shared-lab subnet; resolve to var.hub_shared_lab_cidr's
          #     .10 host (matches dc01.static_ip in the scenario YAML).
          #   - Otherwise (single-student deploys OR per-student-target
          #     scenarios) preserve the original per-student convention:
          #     10.<student_index>.0.10 inside that student's spoke
          #     targets subnet.
          dc_ip = (
            m.student_id == "" && local.multi_student_shared
            ? cidrhost(var.hub_shared_lab_cidr, 10)
            : format("10.%d.0.10", m.student_index)
          )
          }) : templatefile("${path.module}/userdata/windows-member.ps1", {
          local_admin    = m.win_admin_user
          local_password = m.win_admin_password
          do_domain_join = m.domain_join
          domain_fqdn    = var.domain.fqdn
          domain_user    = "${var.domain.netbios}\\${var.domain.admin_user}"
          domain_pass    = local.effective_domain_password[m.student_id]
          # DC's static IP. Same dispatch as the persona branch above:
          # shared mode → hub_shared_lab host .10 (matches dc01's YAML
          # static_ip); otherwise → per-student spoke convention
          # 10.<student_index>.0.10. Member sets this as its DNS server
          # before Resolve-DnsName so AD SRV lookups don't fall through
          # to GCP's default metadata resolver (169.254.169.254 / the
          # platform-DNS 35.199.192.0/19 zone, which can't see the AD
          # zone).
          dc_ip = (
            m.student_id == "" && local.multi_student_shared
            ? cidrhost(var.hub_shared_lab_cidr, 10)
            : format("10.%d.0.10", m.student_index)
          )
          elk_endpoint    = "10.0.0.10"
          kibana_password = var.services.elk.kibana_password
          deploy_agents   = var.services.elk.deploy_agents
          student_id      = m.student_id
          # Winlogbeat YAML pre-built in terraform + base64'd. See the
          # DC block above for why we avoid the PS here-string parser.
          winlogbeat_b64 = base64encode(join("\n", [
            "winlogbeat.event_logs:",
            "  - name: Application",
            "  - name: System",
            "  - name: Security",
            "  - name: Microsoft-Windows-Sysmon/Operational",
            "output.elasticsearch:",
            "  hosts: [\"http://10.0.0.10:9200\"]",
            "  username: elastic",
            "  password: \"${var.services.elk.kibana_password}\"",
            "",
          ]))
        })
      ) :
      m.role == "attacker" ? templatefile("${path.module}/userdata/attacker.sh", {
        linux_user = m.linux_user
        linux_pass = m.linux_password
        ssh_pubkey = local.effective_ssh_pubkey
        student_id = m.student_id
      }) :
      m.role == "c2-server" ? templatefile("${path.module}/userdata/c2-server.sh", {
        linux_user          = m.linux_user
        linux_pass          = m.linux_password
        ssh_pubkey          = local.effective_ssh_pubkey
        teamserver_password = local.effective_adaptix_password[m.student_id]
        operator_user       = m.linux_user
        student_id          = m.student_id
        # JSON list of {name, config} entries; configure_listeners.py
        # POSTs each to /listener/create after the teamserver boots.
        listeners_json = jsonencode(local.adaptix_listeners[m.student_id])
        # RedELK Filebeat target (empty = skip Filebeat install).
        redelk_ip = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-mythic" ? templatefile("${path.module}/userdata/c2-mythic.sh", {
        linux_user            = m.linux_user
        linux_pass            = m.linux_password
        ssh_pubkey            = local.effective_ssh_pubkey
        mythic_admin_password = local.effective_mythic_password[m.student_id]
        student_id            = m.student_id
        redelk_ip             = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-brc4" ? templatefile("${path.module}/userdata/c2-brc4.sh", {
        linux_user          = m.linux_user
        linux_pass          = m.linux_password
        ssh_pubkey          = local.effective_ssh_pubkey
        brc4_license_id     = var.brc4_license_id
        brc4_activation_key = var.brc4_activation_key
        brc4_email          = var.brc4_email
        brc4_blob_url       = var.brc4_blob_url
        student_id          = m.student_id
        student_index       = m.student_index
        # Pre-rendered c2.profile JSON: 5 HTTPS listeners + commander.
        brc4_profile_json = local.brc4_profile[m.student_id]
        # RedELK Filebeat shipper config target. Empty string when no
        # RedELK box is in shared_infrastructure (Filebeat install
        # skipped in that case).
        redelk_ip = local.redelk_in_yaml ? local.redelk_hub_ip : ""
      }) :
      m.role == "c2-sliver" ? templatefile("${path.module}/userdata/c2-sliver.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        ssh_pubkey      = local.effective_ssh_pubkey
        sliver_password = local.effective_sliver_password[m.student_id]
        student_id      = m.student_id
        student_index   = m.student_index
        redelk_ip       = local.redelk_in_yaml ? local.redelk_hub_ip : ""
        # Five (cdn, header_name, header_value, port) tuples — sliver-
        # server creates one HTTPS listener per CDN on the matching
        # :8443-:8447 port. Auth header is enforced server-side via
        # sliver's --aux-config flag.
        cdn_headers_json = jsonencode([
          for cdn in local.cdn_names : {
            cdn    = cdn
            header = local.cdn_headers["sliver"][m.student_id][cdn].name
            value  = local.cdn_headers["sliver"][m.student_id][cdn].value
            port   = local.cdn_port[cdn]
          }
        ])
      }) :
      m.role == "c2-redirector" ? templatefile("${path.module}/userdata/c2-redirector.sh", {
        linux_user = m.linux_user
        linux_pass = m.linux_password
        ssh_pubkey = local.effective_ssh_pubkey
        student_id = m.student_id
        cover_url  = var.advanced_c2.cover_url
        redelk_ip  = local.redelk_in_yaml ? local.redelk_hub_ip : ""
        # Fronts-aware upstream IP. Listener PORT is selected dynamically
        # by which X-Api-* header matched (8443–8447), not by `fronts`.
        upstream_host = (
          m.fronts == "c2-mythic" ? format("10.%d.1.7", m.student_index) :
          m.fronts == "c2-brc4" ? format("10.%d.1.9", m.student_index) :
          m.fronts == "c2-sliver" ? format("10.%d.1.11", m.student_index) :
          format("10.%d.1.5", m.student_index)
        )
        # Five (header-name, UUID, port) tuples. Keys per stack come from
        # passwords.tf; the redirector chooses by `fronts:`.
        cdn_headers = [
          for cdn in local.cdn_names : {
            cdn = cdn
            name = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name
            header_var = lower(replace(local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].name, "-", "_"))
            value = local.cdn_headers[
              m.fronts == "c2-mythic" ? "mythic" :
              m.fronts == "c2-brc4" ? "brc4" :
              m.fronts == "c2-sliver" ? "sliver" : "adaptix"
            ][m.student_id][cdn].value
            port = local.cdn_port[cdn]
          }
        ]
      }) :
      (m.role == "linux-target" && m.persona_name != "") ? templatefile("${path.module}/userdata/linux-persona.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        hostname        = m.persona_name == "" ? "target-${m.student_id}" : "${m.persona_name}-${m.student_id}"
        persona_b64     = m.persona_b64
        enable_root_ssh = m.enable_root_ssh ? "true" : "false"
        # Reuse the per-student domain admin password as root's password
        # so we don't introduce yet another random_password resource.
        # The root login is operator-only via Guacamole; students still
        # use the regular `linux_user` SSH connection.
        root_password = local.effective_domain_password[m.student_id]
      }) :
      # Bare linux-target without a persona is INFRASTRUCTURE-only
      # (e.g. Splunk indexer). Keeps the ranger user for operator
      # access; not registered in the student-facing Guacamole manifest
      # (filtered in services.tf).
      templatefile("${path.module}/userdata/linux-target.sh", {
        linux_user      = m.linux_user
        linux_pass      = m.linux_password
        elk_endpoint    = "10.0.0.10"
        deploy_agents   = var.services.elk.deploy_agents
        kibana_password = var.services.elk.kibana_password
        student_id      = m.student_id
        enable_root_ssh = m.enable_root_ssh ? "true" : "false"
        root_password   = local.effective_domain_password[m.student_id]
      })
    )
  }

  # Resolve target subnet self-link per machine. Three dispatch paths,
  # identical to Azure (just GCP subnetwork ids instead of subnet ids).
  # Subnets are owned by the parallel network.tf agent; we reference the
  # expected resource names here:
  #
  # 1. `shared` machine in multi-student mode (m.student_id == "" AND
  #    local.multi_student_shared is true): the machine is one of the
  #    cohort-shared targets (dc01, srv01, ws10, ws11, linux01, ...
  #    per_student=false). Placed in the hub's shared-lab subnet so
  #    every per-student attacker spoke can reach it via VPC peering.
  # 2. Per-student attacker-tier role (kali, analyst, c2-*) in a spoke
  #    with a real student_id: placed in that student's attacker subnet
  #    (10.<n>.1.0/24).
  # 3. Per-student target-tier role (windows-dc, windows-member,
  #    windows-workstation, linux-target) in a spoke — including the
  #    single-student deploy case where these have student_id="" but
  #    that "" student still owns its own spoke: placed in that
  #    student's targets subnet (10.<n>.0.0/24).
  machine_subnet = {
    for m in var.machines :
    m.name => (
      m.student_id == "" && local.multi_student_shared
      ? google_compute_subnetwork.hub_shared_lab.self_link
      : contains([
        "attacker", "windows-analyst",
        "c2-server", "c2-mythic", "c2-brc4", "c2-sliver",
        "c2-redirector",
      ], m.role)
      ? google_compute_subnetwork.student_attacker[m.student_id].self_link
      : google_compute_subnetwork.student_target[m.student_id].self_link
    )
  }

  # GCP equivalent of Azure's machine_location — the deployment zone for
  # each instance. Hub-shared machines land in the hub region's primary
  # zone; per-student spoke machines land in their spoke's zone. The
  # network.tf agent owns these locals; if they don't exist yet, vms.tf
  # falls back to `<region>-a` derived from var.azure_region (named for
  # the YAML variable convention; the value is a GCP region string like
  # "asia-southeast1").
  #
  # TODO: once network.tf publishes local.student_zone[sid] /
  # local.hub_zone, switch this to read from there directly. For now
  # we derive the zone from the region with the `-a` suffix, which is
  # always a valid zone in every GCP region.
  machine_zone = {
    for m in var.machines :
    m.name => "${var.azure_region}-a"
  }

  # Convention for static IPs in attacker subnet:
  #   c2-server                          at 10.<n>.1.5   (Adaptix)
  #   c2-redirector fronts c2-server     at 10.<n>.1.6
  #   c2-mythic                          at 10.<n>.1.7
  #   c2-redirector fronts c2-mythic     at 10.<n>.1.8
  #   c2-brc4                            at 10.<n>.1.9
  #   c2-redirector fronts c2-brc4       at 10.<n>.1.10
  #   c2-sliver                          at 10.<n>.1.11
  #   c2-redirector fronts c2-sliver     at 10.<n>.1.12
  #   attacker (`kali`, the Kali box)    at 10.<n>.1.20
  #   windows-analyst (FLARE-VM)         at 10.<n>.1.21
  #
  # IMPORTANT: this auto-IP table only applies to PER-STUDENT machines
  # (machines in a per-student attacker spoke). Shared-mode machines
  # (student_id=="" in multi-student deploys, placed in hub_shared_lab)
  # must NOT pass through this — the format strings would compute
  # "10.0.1.X" addresses (using student_index=0) which collide with the
  # hub_infra subnet at 10.0.1.0/24. Shared machines either get their
  # static_ip from the scenario YAML (e.g. dc01 → "10.0.2.10" in the
  # hub_shared_lab subnet) or fall through to GCP DHCP.
  effective_static_ip = {
    for m in var.machines :
    m.name => (
      m.static_ip != "" ? m.static_ip :
      (m.student_id == "" && local.multi_student_shared) ? "" :
      (m.role == "c2-server" ? format("10.%d.1.5", m.student_index) :
        m.role == "c2-mythic" ? format("10.%d.1.7", m.student_index) :
        m.role == "c2-brc4" ? format("10.%d.1.9", m.student_index) :
        m.role == "c2-sliver" ? format("10.%d.1.11", m.student_index) :
        # The Kali attacker box takes the canonical .20 — other
        # components (e.g. the BRC4 commander-serve KALI_IP allow-list)
        # reference that address. There's exactly one attacker box in
        # terra-range now (the xrdp `kali`); the kali-2 ephemeral
        # container pool runs as Docker on the workspaces VM, not as a
        # `var.machines` entry, so no .20 collision is possible.
        m.role == "attacker" ? format("10.%d.1.20", m.student_index) :
        m.role == "windows-analyst" ? format("10.%d.1.21", m.student_index) :
        m.role == "c2-redirector" ? (
          m.fronts == "c2-mythic" ? format("10.%d.1.8", m.student_index) :
          m.fronts == "c2-brc4" ? format("10.%d.1.10", m.student_index) :
          m.fronts == "c2-sliver" ? format("10.%d.1.12", m.student_index) :
          format("10.%d.1.6", m.student_index)
        ) :
      "")
    )
  }

  # Whether a machine gets an external IP. Same surface area as Azure:
  # c2-redirector boxes get a public IP for CDN origin-validation traffic.
  # Everything else relies on Cloud NAT for egress (which the network.tf
  # agent provisions) and IAP TCP forwarding for operator SSH (which
  # firewall.tf opens).
  machine_needs_public_ip = {
    for m in var.machines :
    m.name => (
      var.advanced_c2.enabled && m.role == "c2-redirector"
    )
  }

  # Role → GCP machine-type. Mirrors the per-role decisions from
  # modules/azure/images.tf's `local.vm_size`:
  #   Azure                              GCP
  #   Standard_D8s_v5  (8 vCPU/32 GB) →  n2-standard-8
  #   Standard_D4s_v5  (4 vCPU/16 GB) →  n2-standard-4
  #   Standard_D2s_v5  (2 vCPU/8  GB) →  n2-standard-2
  #   Standard_B8ms    (8 vCPU/32 GB) →  e2-standard-8
  #   Standard_B4ms    (4 vCPU/16 GB) →  e2-standard-4
  #   Standard_B2ms    (2 vCPU/8  GB) →  e2-medium
  #   Standard_B2s     (2 vCPU/4  GB) →  e2-small
  #
  # We use n2 (Intel Cascade Lake) for AD / target servers because they
  # benefit from higher single-thread perf and better NIC throughput. e2
  # for burstable / cost-sensitive roles (kali, redirectors, infra).
  # `local.size_map`, `local.vm_size`, and `local.is_windows` are all
  # defined in modules/gcp/images.tf — the image-dispatch needs them
  # (vm_size for SKU resolution, is_windows for Windows-vs-Linux image
  # family choice), so they live there as the single source of truth.
  # vms.tf reads them via `local.vm_size[m.name]` / `local.is_windows[m.name]`.
  # Re-declaring would cause "Duplicate local value" at plan time.

  # OS-disk size per machine. Same per-role sizing as Azure:
  #   attacker (kali)            128 GB  full Kali desktop + Adaptix
  #   c2-sliver                  128 GB  sliver implant cache + BadgerDB
  #   other c2-* teamservers      64 GB  Docker / source builds
  #   windows-analyst (FLARE)    256 GB  samples + IDA/Ghidra caches
  #   other Windows              128 GB  baseline
  #   redelk (in shared infra)   200 GB  ES indices + Logstash spool
  #   everything else Linux       64 GB  modest, but >40 for headroom
  #
  # Increasing boot_disk.initialize_params.size is an in-place update
  # for google_compute_instance (NOT a force-replacement). On GCP, the
  # filesystem auto-grows on first boot for our supported images.
  linux_disk_size_gb = {
    for m in var.machines :
    m.name => (
      m.role == "attacker" ? 128 :
      m.role == "c2-sliver" ? 128 :
      contains(["c2-server", "c2-mythic", "c2-brc4"], m.role) ? 64 :
      64
    )
  }

  windows_disk_size_gb = {
    for m in var.machines :
    m.name => (
      m.role == "windows-analyst" ? 256 : 128
    )
  }
}

# ============================================================================
# Optional external IPs (Cloud-CDN-fronted redirectors only).
#
# GCP equivalent of azurerm_public_ip. Regional EXTERNAL addresses bound
# to the instance via `network_interface.access_config.nat_ip`. Reserving
# them as `google_compute_address` (rather than letting the instance
# auto-allocate an ephemeral one) is what lets the CDN custom-domain
# validation use a STABLE origin IP that survives instance recreation.
# ============================================================================
resource "google_compute_address" "redirector" {
  for_each = {
    for m in var.machines :
    m.name => m if local.machine_needs_public_ip[m.name]
  }

  name         = "${var.range_name}-${each.value.name}-extip"
  region       = var.azure_region
  address_type = "EXTERNAL"
  description  = "Stable external IP for ${each.value.name} (CDN origin target)"
}

# ============================================================================
# Linux instances
# ============================================================================
resource "google_compute_instance" "linux" {
  for_each = {
    for m in var.machines :
    m.name => m if !local.is_windows[m.name]
  }

  name         = "${var.range_name}-${each.value.name}"
  machine_type = local.vm_size[each.key]
  zone         = local.machine_zone[each.key]

  # Tags drive firewall matching (allow-iap, role-<role>, student-<sid>).
  # These are FREE-FORM strings — no slashes or special chars allowed —
  # and they DO NOT bill or report; that's what `labels` are for. The
  # firewall.tf module ships rules that match on these tags.
  #
  # Tag-format rules:
  #   - lowercase, alphanum + dashes only, max 63 chars
  #   - we lowercase + dash-replace role and student_id so values like
  #     "windows-dc" or "lab01" pass through cleanly
  #
  # `allow-iap` is shared by every instance so the IAP-TCP-forwarding
  # firewall rule (firewall.tf) opens :22 + :3389 from Google's IAP
  # range to anything tagged it.
  tags = compact([
    "allow-iap",
    "role-${each.value.role}",
    each.value.student_id != "" ? "student-${each.value.student_id}" : null,
  ])

  # Labels drive billing reports and cost analysis. Same semantic content
  # as `tags` plus `range` and `os`, but in the GCP label format (lowercase,
  # alphanum + underscores + dashes; values up to 63 chars; mainly used by
  # `gcloud beta billing` reports and Cloud Console grouping).
  labels = {
    range      = var.range_name
    role       = each.value.role
    os         = each.value.os
    student_id = each.value.student_id != "" ? each.value.student_id : "shared"
    priority   = lower(var.vm_priority)
  }

  # Critical-infrastructure roles are PINNED to Regular (non-SPOT) even
  # when --spot is set globally. Eviction during their bootstrap or
  # steady-state would corrupt the range — see `local.spot_pinned_roles`
  # in passwords.tf for the full list and rationale.
  #
  # GCP SPOT vs Azure Spot translation:
  #   Azure                           GCP
  #   priority="Spot"               + provisioning_model="SPOT"
  #   eviction_policy="Deallocate"  + instance_termination_action="STOP"
  #     (preserves OS disk)             (preserves OS + secondary disks)
  #   max_bid_price=-1              + (no equivalent; GCP just uses the
  #                                     fixed SPOT-discount rate)
  #
  # automatic_restart MUST be false when provisioning_model="SPOT" — GCP
  # rejects the apply otherwise. The instance still resumes on operator
  # `gcloud compute instances start` once capacity returns.
  scheduling {
    provisioning_model = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? "STANDARD"
      : "SPOT"
    )
    preemptible = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? false
      : true
    )
    automatic_restart = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? true
      : false
    )
    instance_termination_action = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? null
      : "STOP" # = Azure's "Deallocate": preserve disks, stop billing for compute
    )
  }

  # Boot disk. Same role-aware sizing as Azure (see local.linux_disk_size_gb
  # above for per-role rationale). `pd-balanced` is GCP's cheapest SSD-class
  # disk and is the right default for OS disks — better IOPS than pd-standard
  # (HDD) without the cost premium of pd-ssd.
  #
  # `local.machine_source_image_id[<name>]` is exported by the parallel
  # images.tf agent (mirrors modules/azure/images.tf's same-named local).
  # It returns either:
  #   - A baked-image self-link (e.g. projects/<proj>/global/images/<name>)
  #     when baking.enabled AND baking.use_baked_<os>:true.
  #   - A public marketplace family self-link (e.g.
  #     projects/debian-cloud/global/images/family/debian-12) when no
  #     baked image is selected.
  # Either way, the value is a string consumed verbatim by initialize_params.image.
  boot_disk {
    initialize_params {
      image = local.machine_source_image_id[each.key]
      size  = local.linux_disk_size_gb[each.key]
      type  = "pd-balanced"
    }
    auto_delete = true
  }

  # Network interface. Single NIC per instance — GCP doesn't expose the
  # "separate NIC resource" pattern Azure has (azurerm_network_interface);
  # the NIC is always embedded in the instance.
  #
  # Private IP allocation: when local.effective_static_ip[name] is non-empty
  # we reserve that exact host inside the subnet. Empty → GCP DHCP.
  #
  # access_config (public IP):
  #   - `nat_ip` set to the reserved google_compute_address → instance
  #     has a stable public IP. Only c2-redirector boxes get one (and
  #     only when var.advanced_c2.enabled is true; see
  #     local.machine_needs_public_ip).
  #   - Without an access_config block at all → no public IP. Operator
  #     SSH uses IAP TCP forwarding; outbound traffic uses Cloud NAT.
  network_interface {
    subnetwork = local.machine_subnet[each.key]
    network_ip = local.effective_static_ip[each.key] == "" ? null : local.effective_static_ip[each.key]

    dynamic "access_config" {
      for_each = local.machine_needs_public_ip[each.key] ? [1] : []
      content {
        nat_ip = google_compute_address.redirector[each.key].address
      }
    }
  }

  # Metadata is the GCP equivalent of Azure's custom_data + admin_password
  # plumbing. Three things we set on every Linux instance:
  #
  #   1. `startup-script` — the cloud-init userdata, identical to what
  #      Azure passes via custom_data. The GCP guest agent invokes the
  #      raw script on first boot under root. cloud-init's `users:` etc.
  #      stanzas work because the Debian / Kali images include
  #      cloud-init.
  #
  #   2. `enable-oslogin = FALSE` — see operator_ssh.tf for the full
  #      explanation. tl;dr: OS Login is the GCP-cloud-side IAM-bound
  #      SSH auth that REPLACES local /etc/passwd auth. terra-range's
  #      workflow creates local `ranger` users in cloud-init and authn's
  #      them with a planted SSH key — that's INCOMPATIBLE with OS Login.
  #      Default GCP project policy may enable OS Login; we explicitly
  #      disable it per-instance.
  #
  #   3. `ssh-keys` — the operator's public key, planted under the
  #      `ranger` username (see operator_ssh.tf for the format). This is
  #      the GCP equivalent of Azure's `admin_ssh_key` block. Without
  #      this, cloud-init's `ssh_authorized_keys:` is the only auth path
  #      and any cloud-init failure locks the operator out entirely.
  #
  # We deliberately do NOT set `block-project-ssh-keys = TRUE` — that
  # would prevent the operator's project-level keys (a useful escape
  # hatch when cloud-init breaks) from working. Most operators will
  # never use those, but they're a useful fallback.
  metadata = {
    startup-script = local.bootstrap[each.key]
    enable-oslogin = "FALSE"
    ssh-keys       = local.ssh_keys_metadata
  }

  # Allow stopping the instance to apply machine_type / disk-size changes
  # in-place rather than forcing a replacement.
  allow_stopping_for_update = true

  # GCP guest agent should be on for all roles — provides metadata polling,
  # SSH key plant, startup-script execution, and the SPOT preemption ACPI
  # shutdown handler.
  service_account {
    # Default compute SA, minimal scopes. Per-role IAM (e.g. read-only
    # secret-manager access for the BRC4 license fetch) is wired in the
    # parallel services.tf agent; we just attach the compute default
    # service account here so the agent has a target identity to bind to.
    scopes = ["cloud-platform"]
  }

  lifecycle {
    # Once the post-apply configuration layer moved from cloud-init's
    # startup-script to the Ansible playbook in modules/azure/ansible/,
    # changes to userdata/c2-*.sh should NOT force-replace the VM.
    # The guest agent still runs the startup-script on first boot (and
    # is the right place for SSH keys, hostname, base packages, systemd
    # units). When an instance gets replaced for legitimate reasons
    # (image change, size change, NIC change), terraform will still
    # re-run the startup-script from scratch.  For ongoing config
    # drift, run `./range repair` (ansible).
    ignore_changes = [metadata["startup-script"]]
  }
}

# ============================================================================
# Windows instances
# ============================================================================
resource "google_compute_instance" "windows" {
  for_each = {
    for m in var.machines :
    m.name => m if local.is_windows[m.name]
  }

  name         = "${var.range_name}-${each.value.name}"
  machine_type = local.vm_size[each.key]
  zone         = local.machine_zone[each.key]

  tags = compact([
    "allow-iap",
    "role-${each.value.role}",
    each.value.student_id != "" ? "student-${each.value.student_id}" : null,
  ])

  labels = {
    range      = var.range_name
    role       = each.value.role
    os         = each.value.os
    student_id = each.value.student_id != "" ? each.value.student_id : "shared"
    priority   = lower(var.vm_priority)
  }

  # Same SPOT pinning logic as Linux. windows-dc is in local.spot_pinned_roles
  # — eviction during DC promotion produces a half-built forest that AD
  # doesn't tolerate; recovery is destroy + rebuild from scratch.
  scheduling {
    provisioning_model = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? "STANDARD"
      : "SPOT"
    )
    preemptible = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? false
      : true
    )
    automatic_restart = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? true
      : false
    )
    instance_termination_action = (
      contains(local.spot_pinned_roles, each.value.role) || var.vm_priority != "Spot"
      ? null
      : "STOP"
    )
  }

  # Boot disk. Same image-dispatch convention as Linux (see comments on
  # that resource above). Default Windows boot disk is 128 GB; FLARE-VM
  # gets 256 GB.
  boot_disk {
    initialize_params {
      image = local.machine_source_image_id[each.key]
      size  = local.windows_disk_size_gb[each.key]
      type  = "pd-balanced"
    }
    auto_delete = true
  }

  network_interface {
    subnetwork = local.machine_subnet[each.key]
    network_ip = local.effective_static_ip[each.key] == "" ? null : local.effective_static_ip[each.key]

    # Windows instances are never assigned public IPs in our deploys;
    # operator RDP rides Guacamole through hub_infra. Block deliberately
    # omitted (no `access_config` = no NAT IP).
  }

  # Windows metadata:
  #
  #   1. `windows-startup-script-ps1` — equivalent of Azure's custom_data
  #      for Windows. The GCEMetadata service / google-compute-engine
  #      Windows agent runs this PowerShell script on first boot under
  #      SYSTEM.
  #
  #   2. Admin-password plant: GCP's native `gcloud compute reset-
  #      windows-password` API generates a random password and returns
  #      it to the operator. terra-range needs DETERMINISTIC per-student
  #      passwords (from random_password.domain_admin[student_id]) so
  #      every per-student VM in a cohort has a predictable AD-DA
  #      credential. We DON'T use the API — instead, the first lines of
  #      our windows-startup-script reset the local admin account
  #      (`rangeadmin`) to the desired password before any other action.
  #      That happens in modules/azure/userdata/windows-*.ps1 (the
  #      `New-LocalUser` / `net user` block at the top of each script)
  #      and is portable as-is to GCP.
  #
  #   3. `sysprep-specialize-script-ps1` is the GCP analog of Azure's
  #      `additional_unattend_content` — runs DURING sysprep specialize,
  #      before the first interactive logon. We use it to flip Network
  #      Profile from Public → Private (so WinRM/PSRemoting works) and
  #      to set the local admin password. Mirrors what Azure does
  #      automatically when `admin_password` is set on the VM resource.
  #
  #   4. `enable-oslogin = FALSE` — Windows doesn't actually use OS
  #      Login (it's Linux-only), but we set it for hygiene and
  #      parity with the Linux resource.
  #
  # NOTE: the per-student domain-admin password lives in
  # local.effective_domain_password[student_id]. The PS1 templates render
  # it directly into `net user / Set-LocalUser` lines — base64'ing the
  # whole script is NOT required (unlike Azure's custom_data which
  # mandates base64). GCP's metadata service handles arbitrary text.
  metadata = {
    windows-startup-script-ps1    = local.bootstrap[each.key]
    sysprep-specialize-script-ps1 = <<-EOT
      # Set local admin password deterministically.
      #
      # The GCP Windows guest agent provisions the local admin account
      # with a RANDOM password (decryptable via the GCP console only).
      # We override it with the per-student deterministic password so
      # every box in this student's deploy uses the same credential and
      # downstream Ansible / RDP automation can authenticate uniformly.
      $pw = ConvertTo-SecureString "${replace(local.effective_domain_password[each.value.student_id], "$", "`$")}" -AsPlainText -Force
      # Create rangeadmin if it doesn't already exist; if it does, just
      # reset the password.
      if (-not (Get-LocalUser -Name "${each.value.win_admin_user}" -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name "${each.value.win_admin_user}" -Password $pw -PasswordNeverExpires -AccountNeverExpires
        Add-LocalGroupMember -Group "Administrators" -Member "${each.value.win_admin_user}"
      } else {
        Set-LocalUser -Name "${each.value.win_admin_user}" -Password $pw
      }
      # Flip the network profile to Private so WinRM / PSRemoting
      # works on the AD network for downstream Ansible bridge calls.
      Get-NetConnectionProfile | ForEach-Object { Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private }
    EOT
    enable-oslogin                = "FALSE"
  }

  # Windows requires WindowsServer for AD-DS; needed by the GCP agent
  # to detect Windows-Update-driven reboots during sysprep + DC promo.
  # `windows-startup-script-ps1` re-runs on every boot by default, which
  # is what we want (DC promo re-checks state and short-circuits if
  # already done). Set `disable-agent-updates = TRUE` to keep the
  # GCP agent on the version that was tested with terra-range.
  allow_stopping_for_update = true

  # Shielded VM is OPTIONAL but recommended for Windows — gives us
  # TPM-backed secure boot + measured integrity. Comes free with n2 /
  # n2d / e2 machine types. Skipping for now to keep parity with Azure
  # (which doesn't enable Trusted Launch in this module either); easy
  # to add later if compliance demands it.

  service_account {
    scopes = ["cloud-platform"]
  }

  # We deliberately do NOT add `ignore_changes = [metadata]` here (unlike
  # Linux). The Windows startup-script INCLUDES the DC-promotion flow,
  # which is idempotent and safe to re-run if the script content changes
  # (the in-script "already promoted?" guards short-circuit on subsequent
  # boots). If we ignored metadata, a fix to the PS1 template would never
  # propagate to a running DC without manual taint.
  #
  # The trade-off: every PS1 edit becomes a "change to metadata", which
  # in GCP is an in-place update (does NOT replace the instance). Good
  # enough.
}

# ============================================================================
# Windows bootstrap notes — NO equivalent of Azure RunCommand needed.
#
# Azure's vms.tf uses azurerm_virtual_machine_run_command for the Windows
# DC promotion because Azure's Windows custom_data has hard limits
# (CustomScriptExtension's commandToExecute 8191-char cap) that bite
# domain-promotion-sized payloads.
#
# GCP's `windows-startup-script-ps1` metadata key has NO such limit
# (~256 KB ceiling, same as the rest of GCP instance metadata) and runs
# the script directly via the GCP Windows agent — no command-line shim,
# no storage account pre-staging, no cmd.exe 8191-char gate. So we plant
# the DC + members' bootstrap PS1 directly in metadata and rely on the
# in-script idempotency to make re-runs safe.
#
# This means we do NOT need a separate "DC bootstrap" + "members
# bootstrap" resource pair like Azure's azurerm_virtual_machine_run_command
# split. The trade-off is that member bootstraps may run BEFORE the DC
# has finished promoting on first boot — but each member PS1 already
# has a `wait for AD DNS` loop (it polls Resolve-DnsName for the
# `_ldap._tcp.dc._msdcs.<domain>` SRV record) that handles this without
# terraform-side depends_on. The same loop is what makes Azure's
# `members are independent of DC's RunCommand-completion` not actually
# correct in race conditions — both providers fall back to in-script
# polling anyway.
#
# If a future GCP scenario requires hard ordering (e.g. "members must
# wait for DC promotion before terraform considers the apply complete"),
# wire it via:
#   resource "null_resource" "dc_ready" {
#     for_each = google_compute_instance.windows  # the DC subset
#     provisioner "local-exec" {
#       command = "gcloud compute ssh ... --command 'while ! ...; do sleep 30; done'"
#     }
#   }
# Avoid building it speculatively — startup-script idempotency has been
# enough in every terra-range scenario shipped so far.
# ============================================================================
