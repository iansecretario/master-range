################################################################################
# Hub-tier shared infrastructure: Ghostwriter, SteppingStones, RedELK.
# (GCP port of modules/azure/shared_infra.tf.)
#
# These deploy once per range (not per student). Each box gets:
#   - private IP in hub-infra subnet (10.0.1.0/24, see network.tf)
#   - optional external IP gated to operator CIDRs for the web UI
#   - SSH connection auto-registered in Guacamole under the "shared-infra"
#     connection group (manifest is built in services.tf)
#
# C2 teamservers (Adaptix / Mythic / BRC4 / Sliver) are NOT shared infra —
# they all live in the per-student attacker subnet. RedELK is the only
# logging-sink shared infra; per-student C2 boxes ship their logs to it
# via Filebeat (configured in their userdata).
#
# Userdata note: we deliberately reuse the Azure module's cloud-init
# scripts under `modules/azure/userdata/`. They are vanilla cloud-init
# format (no Azure-specific surface), which the GCE metadata server picks
# up identically via the `user-data` metadata key. This avoids forking
# 800+ lines of shell across two providers — change one place, both
# clouds pick it up on next apply.
################################################################################

locals {
  # Pinned hub IP for RedELK so per-student C2 boxes can hard-code it
  # in their Filebeat shipper configs. Logstash listens on :5044. Matches
  # the Azure side's local.redelk_hub_ip — userdata templates rendered
  # for per-student C2 boxes embed this address verbatim.
  redelk_hub_ip = "10.0.1.40"

  redelk_in_yaml = length([
    for s in var.shared_machines : s if s.role == "redelk"
  ]) > 0

  # Pinned hub IP for the ELK VM. Defined here (not in services.tf) because
  # the shared userdata templates need to know where to ship to BEFORE the
  # ELK VM is rendered — same chicken/egg avoidance as the Azure side.
  elk_hub_ip = "10.0.0.10"

  # Per-shared-machine userdata, rendered from the Azure module's cloud-init
  # scripts (single source of truth across both providers). All scripts
  # accept the same templatefile vars; if a future GCP-only knob is needed,
  # fork the script into modules/gcp/userdata/ and switch the path here.
  shared_userdata = {
    for s in var.shared_machines :
    s.name => templatefile(
      "${path.module}/userdata/${s.role}.sh",
      {
        linux_user      = s.linux_user
        linux_pass      = s.linux_password
        ssh_pubkey      = local.effective_ssh_pubkey
        elk_endpoint    = local.elk_hub_ip
        kibana_password = var.services.elk.kibana_password
      }
    )
  }

  # Pinned-IP map: RedELK has a static private IP so Filebeat configs on
  # per-student C2 boxes can hard-code the shipper endpoint. Everything
  # else gets EPHEMERAL (GCE auto-assigns from the subnet pool). Mirrors
  # the `private_ip_address_allocation = "Static"` branch on Azure.
  shared_pinned_ip = {
    for s in var.shared_machines :
    s.name => s.role == "redelk" ? local.redelk_hub_ip : null
  }
}

################################################################################
# External (regional) static IPs — one per shared box that wants public_ip.
# GCP's google_compute_address is the closest analog to azurerm_public_ip:
#   - regional scope (matches our single-region deploy)
#   - PREMIUM tier = anycast-routed (vs STANDARD which is per-region anycast).
#     PREMIUM is required for tier-1 firewall rule consistency.
#   - reserved upfront so the address survives a VM stop/start cycle, and
#     so cdn.tf / DNS records below can reference it before the VM exists.
################################################################################

resource "google_compute_address" "shared" {
  for_each = { for s in var.shared_machines : s.name => s if s.public_ip }

  name         = "${var.range_name}-${each.key}-pip"
  project      = var.gcp_project_id
  region       = var.azure_region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  description = "Public IP for shared-infra ${each.key} (role=${each.value.role})"
}

################################################################################
# Shared-infra compute instances.
#
# Each VM:
#   - lives in the hub-infra subnet (10.0.1.0/24)
#   - has the operator's SSH pubkey planted via metadata.ssh-keys
#   - has OS Login DISABLED — we use the ranger key directly, same as the
#     per-student VMs. enabling OS Login would force operators to manage
#     short-lived IAP-issued keys via gcloud, which breaks the
#     "ssh -i operator-id_ed25519 ranger@<ip>" workflow consumed by Ansible.
#   - runs the matching cloud-init script from modules/azure/userdata/ via
#     metadata.user-data (the GCE Linux Guest Agent pipes this key through
#     cloud-init exactly like the AWS / Azure metadata services).
#   - tagged ["shared", <role>, "allow-iap"] so firewall.tf rules can
#     scope ingress per-role. allow-iap opens 22/3389 to GCP IAP's TCP
#     forwarder range — operator fallback path when the public IP is off.
#   - labelled with role / range / tier so cost grouping + the operator
#     UI can filter on these.
#
# Boot-disk sizing: 60 GB normal; 200 GB for RedELK (Elasticsearch indices
# need the headroom — a busy range can write 30-50 GB/week of beacon logs).
################################################################################

resource "google_compute_instance" "shared" {
  for_each = { for s in var.shared_machines : s.name => s }

  name         = "${var.range_name}-${each.key}"
  project      = var.gcp_project_id
  zone         = local.gcp_zone
  machine_type = each.value.size # scenario YAML supplies a real GCE type (e.g. e2-standard-4)

  description = "Shared-infra ${each.value.role} for range ${var.range_name} (deployed ${local.deploy_timestamp})"

  # GCE Spot equivalent. Same trade-off as Azure: 60–90% cheaper but can be
  # preempted with 30s ACPI notice. Eviction is destructive — disk + config
  # PRESERVED but the instance is STOPPED; operator runs `gcloud compute
  # instances start <name>` when capacity returns. Pinned roles (RedELK
  # mid-index-flush is the canary) stay Regular even with vm_priority=Spot
  # — see passwords.tf's local.spot_pinned_roles for the list.
  scheduling {
    provisioning_model          = var.vm_priority == "Spot" ? "SPOT" : "STANDARD"
    preemptible                 = var.vm_priority == "Spot" ? true : false
    automatic_restart           = var.vm_priority == "Spot" ? false : true
    on_host_maintenance         = var.vm_priority == "Spot" ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.vm_priority == "Spot" ? "STOP" : null
  }

  boot_disk {
    auto_delete = true
    device_name = "${var.range_name}-${each.key}-osdisk"
    initialize_params {
      # RedELK: 200 GB (Elasticsearch index headroom).
      # Everything else: 60 GB (matches Azure shared infra default).
      size = each.value.role == "redelk" ? 200 : 60
      type = "pd-balanced"
      # Per-shared-machine image dispatch comes from images.tf. Returns null
      # when no baked image exists yet; fall back to a Marketplace family
      # based on s.os. The images.tf agent owns this map — see its file for
      # the per-role baked-image precedence chain.
      image = coalesce(
        local.shared_source_image_id[each.key],
        # Marketplace fallback: any debian-12 / ubuntu-22 baseline works
        # for the shared roles. images.tf is expected to expose
        # local.image_family_for[os] for this; until then default to
        # debian-12 which all three shared-infra cloud-init scripts
        # (ghostwriter / stepping-stones / redelk) target.
        "debian-cloud/debian-12"
      )
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.hub_infra.name
    network_ip = local.shared_pinned_ip[each.key] # null for most roles; pinned only for redelk

    # External IP block ONLY when public_ip = true. access_config{} with
    # nat_ip referencing the reserved google_compute_address forces GCE to
    # use exactly that address (vs auto-assigning an ephemeral one).
    dynamic "access_config" {
      for_each = each.value.public_ip ? [1] : []
      content {
        nat_ip       = google_compute_address.shared[each.key].address
        network_tier = "PREMIUM"
      }
    }
  }

  metadata = {
    # Plant the operator's pubkey for the `linux_user` account (default
    # "ranger" in scenario YAML). Format is GCE-specific: each line is
    # `<username>:<pubkey>` and gets fed to ~/<username>/.ssh/authorized_keys
    # by the GCE Linux Guest Agent. We append `operator@terra-range` as the
    # key comment so `ssh -vT` output is unambiguous about which key the
    # range planted.
    ssh-keys = "${each.value.linux_user}:${local.effective_ssh_pubkey} operator@terra-range"

    # OS Login is the Google-managed alternative to manual ssh-keys (it
    # provisions per-user POSIX accounts from IAM). We explicitly disable
    # because:
    #   1. Operators authenticate with the auto-generated ed25519 keypair,
    #      not their personal IAM identity.
    #   2. Ansible's ProxyJump chain assumes a stable username (`ranger`,
    #      `guacadmin`); OS Login mangles names to `<email>_<domain>_com`
    #      which would break every playbook's `remote_user`.
    enable-oslogin = "FALSE"

    # cloud-init userdata. GCE Linux Guest Agent reads this metadata key
    # and pipes it to cloud-init exactly like Azure's custom_data /
    # AWS's user-data. Same script content, both providers.
    user-data = local.shared_userdata[each.key]

    # Disable the default GCE serial-console screen-scrape login prompt
    # ("Generating cloud-init metadata..." spam). Operators get the same
    # console via `gcloud compute instances get-serial-port-output`.
    serial-port-enable = "FALSE"
  }

  # Network tags drive every firewall rule in firewall.tf. Mirrors
  # azurerm_network_interface.shared's NSG association on the Azure side.
  #   - "shared"     : applies hub-infra default allow-out + log
  #   - "hub"        : east-west among hub-tier boxes (allow_east_west_hub)
  #   - "hub-infra"  : operator → ghostwriter/redelk/stepping-stones web
  #                    (allow_operator_hub_web) + Filebeat/redirector logs
  #                    → RedELK ingest (allow_logs_to_hub_infra). Without
  #                    these the shared boxes are unreachable for both the
  #                    operator UI and log ingestion.
  #   - <role>       : per-role rule (e.g. "ghostwriter" opens :443 from
  #                    operator CIDRs; "redelk" opens :5044 from spokes)
  #   - "allow-iap"  : opens 22/3389 to GCP IAP's TCP forwarder range
  #                    (35.235.240.0/20) — operator fallback path.
  tags = ["shared", "hub", "hub-infra", each.value.role, "allow-iap"]

  labels = merge(local.common_labels, {
    role = each.value.role
    tier = "hub"
  })

  # Don't reboot the VM when somebody changes machine_type in the YAML —
  # makes scenario re-applies survive. Same rationale as the Azure
  # ignore_changes on os_disk caching.
  allow_stopping_for_update = true

  # Same rationale as the Guacamole / ELK / per-student Linux VMs on the
  # Azure side: a cloud-init userdata rewrite in the module should NOT
  # force-replace a running shared infra box. Replacing one wipes its app
  # state — RedELK loses every Elasticsearch index, SteppingStones drops
  # its sqlite DB (case notes, operator activity, ticket queue). Pick up
  # userdata changes in place via `./range fix <name> --legacy`, which
  # re-runs the current cloud-init through `gcloud compute ssh`-driven
  # cloud-init re-exec without destroying the disk.
  lifecycle {
    ignore_changes = [
      metadata["user-data"],
      labels["created"],
      description,
    ]
  }
}
