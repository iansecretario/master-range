################################################################################
# Hub services: Guacamole (entry point) + ELK.
# (GCP port of the Guacamole + ELK halves of modules/azure/services.tf.
# The Azure original is ~570 lines because it also contains Adaptix, the
# C2 redirectors, and the workspaces pool — those live in their own per-
# agent files on the GCP side: vms.tf owns Adaptix + redirectors, and the
# workspaces VM is deferred until the ephemeral-Kali pool lands on GCP.)
#
# The Guacamole VM is rendered with a JSON manifest of every machine + its
# private IP + creds + role + student_id. On first boot the VM brings up
# guacd+guacamole+postgres via docker compose, then a Python script uses
# Guacamole's REST API to:
#   - create one connection group per student
#   - create an RDP/SSH connection for every machine, prefilled with creds,
#     placed inside the right student's group
#   - create one Guacamole user per student, granted READ access to ONLY
#     their own connection group
#
# Because every google_compute_instance.* is created BEFORE this VM
# (depends_on below), every private IP is resolved at template-render time.
################################################################################

locals {
  # Map of lab_users name → password (for assigned_user lookups below).
  # When domain.lab_users is empty (default), this is `{}` and no
  # extra connections get registered. Identical shape to the Azure side
  # so the connection-manifest generator below stays portable.
  _lab_user_pwd = { for u in var.domain.lab_users : u.name => u.password }

  # ELK as a Guacamole-registered SSH connection. When public_ip is off
  # (services.elk.public_ip = false), this is the only easy way for an
  # operator to ssh in. Always registered when ELK is enabled — same
  # shape as a shared infra entry.
  _elk_guac_entry = var.services.elk.enabled ? [{
    name        = "elk"
    base_name   = "elk"
    student_id  = "shared-infra"
    role        = "elk"
    os          = "ubuntu-22"
    hostname    = local.elk_hub_ip
    protocol    = "ssh"
    username    = "elkadmin"
    password    = var.services.elk.kibana_password
    port        = 22
    domain_join = false
    sftp = {
      enabled          = true
      hostname         = local.elk_hub_ip
      port             = 22
      username         = "elkadmin"
      password         = var.services.elk.kibana_password
      root-directory   = "/home/elkadmin"
      directory        = "/home/elkadmin"
      disable-upload   = false
      disable-download = false
    }
  }] : []

  # Build the connection manifest. EXACTLY the same shape as the Azure
  # services.tf manifest — register.py on the Guacamole VM is provider-
  # agnostic and just walks this JSON.
  #   1. Base entry per per-student machine: Windows = RDP-as-local-admin,
  #      Linux = SSH-as-ranger.
  #   2. Per Windows member with `assigned_user` set: extra RDP entry
  #      logging in as that domain user (the "regular domain user" tier).
  #   3. Per Linux machine with `enable_root_ssh: true`: extra SSH entry
  #      logging in as root.
  #   4. Per shared-infra box: SSH entry.
  #   5. ELK SSH entry (always when ELK is enabled).
  #
  # IPs come from local.machine_private_ip[m.name]
  # — vms.tf is owned by another agent but the resource name is part of
  # the cross-agent contract documented at the top of main.tf.
  guac_connections = concat(
    # 1. Base per-machine
    [
      for m in var.machines : {
        name       = m.name
        base_name  = m.base_name
        student_id = m.student_id
        role       = m.role
        os         = m.os
        hostname   = local.machine_private_ip[m.name]
        # Protocol per role:
        #   - Windows machines    -> RDP/3389 (always)
        #   - Linux "attacker"    -> VNC/5901 (Kali) UNLESS base_name=="kali"
        #     in which case RDP/3389 via the kali role's xrdp+Xvnc stack
        #   - any other Linux     -> SSH/22 (servers, redirectors, targets)
        protocol = (
          local.is_windows[m.name] ? "rdp" :
          m.base_name == "kali" ? "rdp" :
          m.role == "attacker" ? "vnc" :
          "ssh"
        )
        username = local.is_windows[m.name] ? m.win_admin_user : m.linux_user
        # Use the ACTUAL provisioned admin password for Windows boxes,
        # not m.win_admin_password from the scenario YAML. vms.tf sets
        # the Windows admin password to local.effective_domain_password
        # [student_id] (random_password.domain_admin) at VM-create time,
        # so that's what Windows actually accepts on the wire.
        password = local.is_windows[m.name] ? local.effective_domain_password[m.student_id] : m.linux_password
        port = (
          local.is_windows[m.name] ? 3389 :
          m.base_name == "kali" ? 3389 :
          m.role == "attacker" ? 5901 :
          22
        )
        domain_join = m.domain_join
        # SFTP overlay on EVERY Linux connection — see the long comment
        # in modules/azure/services.tf around line 119 for the rationale.
        # Windows excluded (gets native RDP drive redirection); kali gets
        # the SFTP overlay (despite being RDP-protocol) because chansrv
        # crashes when Linux xrdp tries drive redirection.
        sftp = local.is_windows[m.name] ? null : {
          enabled          = true
          hostname         = local.machine_private_ip[m.name]
          port             = 22
          username         = m.linux_user
          password         = m.linux_password
          root-directory   = "/home/${m.linux_user}"
          directory        = m.role == "attacker" ? "/home/${m.linux_user}/Downloads" : "/home/${m.linux_user}"
          disable-upload   = false
          disable-download = false
        }
      }
    ],
    # 2. Extra Windows RDP-as-domain-user (regular user tier).
    [
      for m in var.machines : {
        name        = "${m.name} (${m.assigned_user}@${var.domain.netbios})"
        base_name   = m.base_name
        student_id  = m.student_id
        role        = m.role
        os          = m.os
        hostname    = local.machine_private_ip[m.name]
        protocol    = "rdp"
        username    = "${var.domain.netbios}\\${m.assigned_user}"
        password    = lookup(local._lab_user_pwd, m.assigned_user, "")
        port        = 3389
        domain_join = m.domain_join
        sftp        = null
      }
      if local.is_windows[m.name] && m.assigned_user != "" && contains(keys(local._lab_user_pwd), m.assigned_user)
    ],
    # 3. Extra Linux SSH-as-root (for boxes that opt in via enable_root_ssh).
    [
      for m in var.machines : {
        name       = "${m.name} (root)"
        base_name  = m.base_name
        student_id = m.student_id
        role       = m.role
        os         = m.os
        hostname   = local.machine_private_ip[m.name]
        protocol   = "ssh"
        username   = "root"
        # Linux root password = per-student domain admin password (set in
        # linux-target.sh / linux-persona.sh when enable_root_ssh=true).
        password    = local.effective_domain_password[m.student_id]
        port        = 22
        domain_join = false
        sftp = {
          enabled          = true
          hostname         = local.machine_private_ip[m.name]
          port             = 22
          username         = "root"
          password         = local.effective_domain_password[m.student_id]
          root-directory   = "/"
          directory        = "/root"
          disable-upload   = false
          disable-download = false
        }
      }
      if !local.is_windows[m.name] && m.enable_root_ssh
    ],
    # 4. Shared infra (Ghostwriter / SteppingStones / RedELK). IPs come
    #    from google_compute_instance.shared[s.name] which we own here.
    [
      for s in var.shared_machines : {
        name        = s.name
        base_name   = s.name
        student_id  = "shared-infra"
        role        = s.role
        os          = s.os
        hostname    = google_compute_instance.shared[s.name].network_interface[0].network_ip
        protocol    = "ssh"
        username    = s.linux_user
        password    = s.linux_password
        port        = 22
        domain_join = false
        sftp = {
          enabled          = true
          hostname         = google_compute_instance.shared[s.name].network_interface[0].network_ip
          port             = 22
          username         = s.linux_user
          password         = s.linux_password
          root-directory   = "/home/${s.linux_user}"
          directory        = "/home/${s.linux_user}"
          disable-upload   = false
          disable-download = false
        }
      }
    ],
    # 5. ELK
    local._elk_guac_entry,
  )

  guac_manifest = jsonencode({
    admin = {
      username = var.services.guacamole.admin_user
      password = local.effective_guacamole_admin_password
    }
    students     = var.student_users
    connections  = local.guac_connections
    autoregister = var.services.guacamole.autoregister
  })
}

################################################################################
# ELK VM (must exist before Guacamole so its private IP is in the manifest)
#
# Single hub-tier Elasticsearch + Kibana + Filebeat-receiver. Per-student
# C2 boxes ship logs here via Filebeat → Logstash on :5044. External IP
# is optional (var.services.elk.public_ip default = true); when off,
# operators reach Kibana through Guacamole's internal connection.
#
# Sizing rationale:
#   e2-standard-4 (4 vCPU / 16 GB) — Elasticsearch's JVM heap is set to
#   8 GB (50% of total per Elastic's tuning guide), leaving headroom for
#   the OS + Filebeat receiver. Burst CPU class is fine because ELK's
#   query pattern is bursty (the operator opens Kibana for a few minutes
#   between long idle stretches).
################################################################################

resource "google_compute_address" "elk" {
  count        = var.services.elk.enabled && var.services.elk.public_ip ? 1 : 0
  name         = "${var.range_name}-elk-pip"
  project      = var.gcp_project_id
  region       = var.azure_region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  description  = "Public IP for hub ELK VM (Kibana web UI :5601)"
}

resource "google_compute_instance" "elk" {
  count = var.services.elk.enabled ? 1 : 0

  name         = "${var.range_name}-elk"
  project      = var.gcp_project_id
  zone         = local.gcp_zone
  machine_type = "e2-standard-4" # 4 vCPU / 16 GB — see header comment

  description = "Hub ELK (Elasticsearch + Kibana + Filebeat receiver) for range ${var.range_name}"

  scheduling {
    provisioning_model          = var.vm_priority == "Spot" ? "SPOT" : "STANDARD"
    preemptible                 = var.vm_priority == "Spot" ? true : false
    automatic_restart           = var.vm_priority == "Spot" ? false : true
    on_host_maintenance         = var.vm_priority == "Spot" ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.vm_priority == "Spot" ? "STOP" : null
  }

  boot_disk {
    auto_delete = true
    device_name = "${var.range_name}-elk-osdisk"
    initialize_params {
      size = 100 # GB — Elasticsearch indices + 30-day retention
      type = "pd-balanced"
      # Prefer the baked ELK image when available (images.tf agent owns
      # local.baked_elk_id; null when no baked version exists yet). Falls
      # back to Marketplace Ubuntu 22.04 LTS.
      image = coalesce(
        try(local.baked_elk_id, null),
        "ubuntu-os-cloud/ubuntu-2204-lts"
      )
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.hub_mgmt.name
    # Pin the ELK private IP. The guac manifest above references this
    # literal address (10.0.0.10), and per-student C2 box userdata writes
    # it into Filebeat configs.
    network_ip = local.elk_hub_ip

    dynamic "access_config" {
      for_each = var.services.elk.public_ip ? [1] : []
      content {
        nat_ip       = google_compute_address.elk[0].address
        network_tier = "PREMIUM"
      }
    }
  }

  metadata = {
    # Operator key for `ssh ranger@<elk-ip>` (when public_ip=true) and for
    # Guacamole's internal SSH connection (always). Same key planted on
    # every other Linux VM in the range.
    ssh-keys = "elkadmin:${local.effective_ssh_pubkey} operator@terra-range"

    enable-oslogin     = "FALSE"
    serial-port-enable = "FALSE"

    user-data = templatefile("${path.module}/userdata/elk.sh", {
      kibana_user     = var.services.elk.kibana_user
      kibana_password = var.services.elk.kibana_password
    })
  }

  # firewall.tf scopes ingress by these tags:
  #   - "elk"        : opens :5601 (Kibana) from operator CIDRs, :5044
  #                    (Filebeat ingest) from every spoke
  #   - "hub"        : east-west among hub-tier boxes (allow_east_west_hub)
  #   - "hub-infra"  : operator → Kibana + Filebeat → ELK ingest
  #                    (allow_operator_hub_web + allow_logs_to_hub_infra).
  #                    Without it the ELK box can't receive logs or serve
  #                    the Kibana UI to the operator.
  #   - "allow-iap"  : fallback SSH path via IAP TCP forwarder
  tags = ["elk", "hub", "hub-infra", "allow-iap"]

  labels = merge(local.common_labels, {
    role    = "elk"
    tier    = "hub"
    service = "elk"
  })

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [
      metadata["user-data"],
      labels["created"],
      description,
    ]
  }
}

################################################################################
# Guacamole VM
#
# Sizing rationale:
#   e2-medium (2 vCPU / 4 GB) — postgres + guacd + guacamole-webapp +
#   nginx in front. Idle steady-state is well under 1 GB; per-session RAM
#   is dominated by guacd ferrying RDP/VNC frames (~30 MB/active session).
#   Plenty for 10-20 concurrent operator sessions; bump to e2-standard-2
#   if you regularly run 30+ simultaneously.
#
# DNS / TLS plumbing is deliberately MINIMAL here vs the Azure original:
#   - Azure has Azure-assigned cloudapp.azure.com FQDNs on every public IP;
#     GCP does NOT. There is no equivalent "free DNS hostname" on a
#     reserved address. So either:
#       (a) operator supplies services.guacamole.dns_zone_name +
#           custom_hostname → guacamole_dns.tf (parallel agent) creates
#           the Cloud DNS A record, certbot does HTTP-01, and the URL is
#           https://<custom>.<zone>/
#       (b) no custom hostname → cloud-init falls back to a self-signed
#           cert and the URL is https://<public-ip>/. Operator dismisses
#           the cert warning on first visit.
#   - We expose the public IP as the bare URL when no custom hostname is
#     configured (see outputs.tf). The Azure-side `local.guac_effective_fqdn`
#     has its own definition in modules/gcp/guacamole_dns.tf (parallel
#     agent); outputs.tf consumes it identically.
################################################################################

resource "google_compute_address" "guacamole" {
  count        = var.services.guacamole.enabled ? 1 : 0
  name         = "${var.range_name}-guac-pip"
  project      = var.gcp_project_id
  region       = var.azure_region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  description  = "Public IP for Guacamole web UI (operator entry point)"
}

resource "google_compute_instance" "guacamole" {
  count = var.services.guacamole.enabled ? 1 : 0

  name         = "${var.range_name}-guac"
  project      = var.gcp_project_id
  zone         = local.gcp_zone
  machine_type = "e2-medium" # 2 vCPU / 4 GB — see header comment

  description = "Hub Guacamole entry point for range ${var.range_name}"

  scheduling {
    provisioning_model          = var.vm_priority == "Spot" ? "SPOT" : "STANDARD"
    preemptible                 = var.vm_priority == "Spot" ? true : false
    automatic_restart           = var.vm_priority == "Spot" ? false : true
    on_host_maintenance         = var.vm_priority == "Spot" ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.vm_priority == "Spot" ? "STOP" : null
  }

  boot_disk {
    auto_delete = true
    device_name = "${var.range_name}-guac-osdisk"
    initialize_params {
      size = 60 # GB — postgres data + docker images + cert cache
      type = "pd-balanced"
      image = coalesce(
        try(local.baked_guacamole_id, null),
        "ubuntu-os-cloud/ubuntu-2204-lts"
      )
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.hub_mgmt.name
    # Pin the Guac private IP to 10.0.0.20 — matches the Azure side so
    # any operator muscle memory + docs survive the move. Per-student
    # box userdata does NOT reference this; it's only here for parity.
    network_ip = "10.0.0.20"

    access_config {
      nat_ip       = google_compute_address.guacamole[0].address
      network_tier = "PREMIUM"
    }
  }

  # Service account: default Compute Engine SA scoped to the bare minimum
  # for what cloud-init needs (logging + secret access). Mirrors Azure's
  # SystemAssigned managed identity. When DNS-01 wildcard cert issuance
  # ships (parallel guacamole_dns.tf agent), it'll grant this SA the
  # roles/dns.admin role on the Cloud DNS zone.
  service_account {
    # email = default — google-compute-engine-default@<project>.iam.gserviceaccount.com
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform", # Secret Manager + Cloud DNS for certbot-dns-google
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  metadata = {
    ssh-keys = "guacadmin:${local.effective_ssh_pubkey} operator@terra-range"

    enable-oslogin     = "FALSE"
    serial-port-enable = "FALSE"

    user-data = templatefile("${path.module}/userdata/guacamole.sh", {
      admin_user     = var.services.guacamole.admin_user
      admin_password = local.effective_guacamole_admin_password
      manifest_b64   = base64encode(local.guac_manifest)
      # FQDN derivation. Parallel guacamole_dns.tf agent defines
      # `local.guac_effective_fqdn` to pick between the custom hostname
      # (when services.guacamole.dns_zone_name is set) and the bare
      # public IP fallback. try() lets this file render even before that
      # agent's locals are defined — defaults to the public IP.
      guac_fqdn       = try(local.guac_effective_fqdn, google_compute_address.guacamole[0].address)
      guac_acme_email = var.services.guacamole.acme_email
      ssh_pubkey      = local.effective_ssh_pubkey
      # Wildcard cert plumbing — see modules/azure/services.tf around
      # line 422 for the full rationale. On GCP the analog is
      # certbot-dns-google authenticating via the VM's service-account
      # token (no service-account-key file needed). guacamole_dns.tf agent
      # owns the IAM binding that lets this SA write to the zone.
      guac_wildcard_zone     = var.services.guacamole.dns_zone_name
      guac_wildcard_zone_rg  = var.services.guacamole.dns_zone_resource_group
      guac_wildcard_zone_sub = var.services.guacamole.dns_zone_subscription_id
      # Secret Manager equivalent for the Azure Key Vault cert cache.
      # Parallel agent may wire this — try() lets us soft-default to "".
      guac_kv_name = try(google_secret_manager_secret.guac_cert_cache[0].secret_id, "")
    })
  }

  # firewall.tf scopes ingress by these tags:
  #   - "guacamole"  : opens :22/:80/:443 from var.guacamole_ingress_cidrs
  #   - "hub"        : east-west among hub-tier boxes (allow_east_west_hub)
  #                    so guac can reach ELK/Ghostwriter/etc. on the hub
  #   - "allow-iap"  : fallback SSH path via IAP TCP forwarder
  # (Guacamole reaches per-student spoke VMs by its hub-subnet SOURCE IP
  # via allow_hub_to_spoke — that rule is CIDR-sourced, not tag-sourced,
  # so guac doesn't need a spoke tag.)
  tags = ["guacamole", "hub", "allow-iap"]

  labels = merge(local.common_labels, {
    role    = "guacamole"
    tier    = "hub"
    service = "guacamole"
  })

  allow_stopping_for_update = true

  # Guarantees every other compute instance is created before the manifest
  # is rendered, so every network_ip is resolved at template time.
  depends_on = [
    google_compute_instance.linux,
    google_compute_instance.windows,
    google_compute_instance.shared,
    google_compute_instance.elk,
  ]

  # Same rationale as the Linux per-student VMs: a cloud-init userdata
  # rewrite in the module should not force-replace a running Guacamole
  # box — destroying it would wipe the registered RDP connection list +
  # the LE cert state. Reapply userdata changes manually via
  # `./range fix guac --legacy`.
  lifecycle {
    ignore_changes = [
      metadata["user-data"],
      labels["created"],
      description,
    ]
  }
}

################################################################################
# Optional cert-cache Secret Manager secret. Equivalent to the Azure Key
# Vault "lab" instance that caches the Guacamole LE cert across destroy/
# redeploy cycles (bypasses LE rate limits). google_secret_manager_secret
# defines the secret CONTAINER; the actual cert payload is written by
# cloud-init from the VM at runtime via the Cloud SDK + the VM's
# default-SA cloud-platform scope.
#
# Only created when DNS-zone is configured (i.e. we expect to actually
# issue real certs). For plain self-signed self-rolled deploys we skip
# the secret entirely to keep the resource graph minimal.
################################################################################

resource "google_secret_manager_secret" "guac_cert_cache" {
  count = (
    var.services.guacamole.enabled
    && var.services.guacamole.dns_zone_name != ""
    && var.services.guacamole.dns_zone_resource_group != ""
  ) ? 1 : 0

  project   = var.gcp_project_id
  secret_id = "${var.range_name}-guac-cert-cache"

  replication {
    auto {}
  }

  labels = merge(local.common_labels, {
    role    = "guacamole"
    purpose = "cert-cache"
  })
}
