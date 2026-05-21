variable "range_name" {
  type = string
}

# GCP project that owns every regional resource in this module (VPC,
# subnets, Cloud NAT, firewall rules, VMs, disks). Required because
# GCP has no "resource group" — every resource must be project-scoped.
# Mirrors the role of Azure's subscription_id at the provider level,
# but threaded as a variable so the same module can deploy into
# different projects from different envs/* configurations.
variable "gcp_project_id" {
  type        = string
  description = "GCP project ID that owns the range resources (VPC, subnets, NAT, firewall, VMs)."
  validation {
    condition     = length(var.gcp_project_id) >= 6 && length(var.gcp_project_id) <= 30
    error_message = "gcp_project_id must be 6..30 chars (GCP project ID rules)."
  }
}

variable "azure_region" {
  type = string
  # Singapore. Set per-scenario in YAML if you want a different region.
  # NOTE the variable name is `azure_region` for cross-provider symmetry
  # with the Azure module — it holds whichever provider's region string
  # is appropriate. The generator emits the same key on both providers.
  # A future cleanup pass may rename this to `region` everywhere.
  default = "asia-southeast1" # GCP equivalent of southeastasia (Singapore)
}

# Kali Linux is published to GCP Marketplace by an external publisher
# project. The project name has changed historically (`kali-linux-cloud`
# → `kali-linux-public` circa 2022), and may shift again. Make it
# overrideable per-scenario so an operator can pin to a forked / mirrored
# project if Marketplace metadata moves.
#
# When use_baked_kali is true the baked custom-image in the operator's
# OWN project takes priority — this variable only matters for the
# Marketplace fallback path.
variable "kali_marketplace_project" {
  type        = string
  description = "GCP project that publishes the Kali Marketplace image (used as marketplace fallback when use_baked_kali is false)."
  default     = "kali-linux-public"
}

# One-project-per-range model: each `./range apply` provisions its own
# project (var.gcp_project_id above). But the BAKED custom images — the
# 15 published image-families that terra-range bakes via Packer — must
# live in a SHARED, long-lived project so they survive `./range destroy`
# cycles and so multiple concurrent ranges can read them. This is the
# GCP equivalent of Azure's Shared Image Gallery in a separate
# resource group with `lifecycle prevent_destroy`.
#
# When unset (empty string), the module falls back to looking up baked
# images in the per-range project — useful for single-deploy testing
# but not the production pattern. When set, every
# `data "google_compute_image"` block in baking.tf points its
# `project =` attribute here.
#
# Operator-managed setup (one-time, per organization):
#   gcloud projects create terra-range-images        # the shared host project
#   gcloud config set project terra-range-images
#   gcloud services enable compute.googleapis.com
#   # then grant the per-range deploy service account `compute.imageUser`
#   # on this project so per-range deploys can READ but not DELETE.
variable "gcp_host_project_id" {
  type        = string
  description = "Long-lived GCP project holding the shared baked-image registry (and any other org-shared resources). Empty = use the per-range project (single-deploy testing only)."
  default     = ""
}

variable "lockdown" {
  type    = bool
  default = false
}

# All VMs created by this module honour this priority. "Spot" is 60–90%
# cheaper but can be evicted at any time when Azure needs the capacity.
# Acceptable for lab/testing scenarios; risky for live engagements
# (DC eviction breaks domain join, ELK eviction can lose unflushed logs).
# Eviction policy = "Deallocate" → disk + config preserved on eviction;
# operator can `az vm start` to bring it back when capacity returns.
variable "vm_priority" {
  type    = string
  default = "Regular"
  validation {
    condition     = contains(["Regular", "Spot"], var.vm_priority)
    error_message = "vm_priority must be 'Regular' or 'Spot'."
  }
}

variable "guacamole_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "domain" {
  type = object({
    enabled           = bool
    fqdn              = string
    netbios           = string
    admin_user        = string
    admin_password    = string
    safemode_password = string
    # Optional list of regular (non-admin) domain users to seed at DC
    # promotion. Each becomes a member of `Domain Users` only. Used by
    # scenarios like redteam-lab that want per-machine designated test
    # users separate from the domain-admin login.
    lab_users = optional(list(object({
      name     = string
      password = string
    })), [])
  })
}

variable "students" {
  type = object({
    count       = number
    tenancy     = string
    name_format = string
  })
  validation {
    condition     = var.students.count >= 1 && var.students.count <= 254
    error_message = "students.count must be 1..254."
  }
  validation {
    condition     = contains(["shared", "isolated"], var.students.tenancy)
    error_message = "students.tenancy must be 'shared' or 'isolated'."
  }
}

variable "machines" {
  type = list(object({
    name               = string
    base_name          = string
    student_id         = string
    student_index      = number
    role               = string
    os                 = string
    size               = string
    static_ip          = string
    domain_join        = bool
    win_admin_user     = string
    win_admin_password = string
    linux_user         = string
    linux_password     = string
    persona_name       = optional(string, "")
    persona_b64        = optional(string, "")
    fronts             = optional(string, "")
    callsign           = optional(string, "")
    # Lab-access fields (used by redteam-lab; default to empty/false).
    # `assigned_user` references a name in domain.lab_users — Guacamole
    # will register a second RDP connection to this Windows box as that
    # domain user, in addition to the existing local-admin connection.
    assigned_user   = optional(string, "")
    enable_root_ssh = optional(bool, false)
    # Multi-student deployment shape (read by the generator, NOT directly
    # by terraform — terraform sees the fully-expanded machines[] list).
    # `per_student: true` (default) means: when students.count > 1, this
    # machine is duplicated once per student, with name `<base>-<sid>`
    # and student_id set. `per_student: false` means: emit exactly once
    # regardless of students.count — the machine is a SHARED resource
    # every student uses (e.g. the target lab DC, member servers, the
    # operator's BRC4 teamserver). When students.count == 1 the flag has
    # no effect (no expansion happens either way). See ROADMAP.md §1
    # for the `shared` vs `isolated` mode design.
    per_student = optional(bool, true)
  }))
}

variable "student_users" {
  type = list(object({
    student_id = string
    username   = string
    password   = string
  }))
  default = []
}

variable "services" {
  type = object({
    guacamole = object({
      enabled                   = bool
      admin_user                = string
      admin_password            = string
      autoregister              = bool
      student_user_prefix       = optional(string, "student-")
      student_password_template = optional(string, "Student!{n:02d}")
      # Login-page wordmark. Replaces the default "APACHE GUACAMOLE"
      # via a translation override baked into cwr-branding.jar by the
      # Ansible guacamole role. Set via:
      #   ./range gen <scenario> --title "Red Team Labs"
      # Default lives in the generator (`Guidem CWR`).
      login_title = optional(string, "Guidem CWR")
      # ACME contact email used by certbot to register an LE account
      # and receive renewal-reminder mail. The Azure cloudapp.azure.com
      # FQDN has no CAA record so LE will issue a publicly-trusted cert
      # via the HTTP-01 challenge. Set via:
      #   ./range gen <scenario> --acme-email you@example.com
      # The placeholder default is well-formed (so certbot accepts it)
      # but obviously not a real address; LE renewal warnings will go
      # nowhere. Pass a real address if you care about cert expiry mail.
      acme_email = optional(string, "admin@example.com")
      # Optional custom hostname. When `dns_zone_name` is set, terraform
      # creates an Azure DNS A record `<custom_hostname>.<dns_zone_name>`
      # pointing at the Guacamole public IP, AND certbot issues the LE
      # cert against that FQDN instead of the Azure-assigned
      # cloudapp.azure.com one. Falls back to the cloudapp URL when blank.
      #
      # Set via the scenario YAML or:
      #   ./range gen <scenario> --guac-subdomain guac --guac-domain cyberwarrange.com \
      #                          --guac-dns-rg aa_group --guac-dns-sub <azure-subscription-id>
      custom_hostname          = optional(string, "") # short label, e.g. "guac"
      dns_zone_name            = optional(string, "") # apex zone, e.g. "cyberwarrange.com"
      dns_zone_resource_group  = optional(string, "")
      dns_zone_subscription_id = optional(string, "") # blank = same sub as the deploy
    })
    elk = object({
      enabled         = bool
      kibana_user     = string
      kibana_password = string
      deploy_agents   = bool
      # When false, the ELK VM has no public IP. Operators reach Kibana
      # through Guacamole's internal-network connection. Default true
      # for backward compatibility with existing scenarios.
      public_ip = optional(bool, true)
    })
    adaptix = object({
      enabled    = bool
      ssh_pubkey = string
      # Teamserver listens on uniform :9000 commander + :8443–:8447 per-CDN
      # listener ports. Per-student operator passwords are random (see
      # local.effective_adaptix_password in passwords.tf).
    })
    redirector = object({
      enabled = bool
      # Redirector always listens on :443 and selects its upstream port
      # dynamically from which X-Api-* header matched (8443–8447).
    })
    # Ephemeral Kali workspace host. One dedicated VM in hub_infra that
    # pre-spawns a pool of `kali-2` Docker containers (kali-rolling +
    # TigerVNC + XFCE), each exposed on a unique host port (5901, 5902,
    # …). Guacamole registers one shared `kali-2-<i>` VNC connection per
    # slot. Containers run with `--rm` and a per-slot tmpfs $HOME, so
    # restarting one wipes operator state — "zero state accumulation".
    #
    # Lives on its OWN VM (not co-located with Guacamole) because:
    #   - Kali containers run aggressive pentest tools; container-escape
    #     blast radius must NOT include the Guac control plane (Postgres
    #     creds, nginx TLS keys, the operator's SSH jump host).
    #   - Per-container RAM = ~2-3 GB. Guac VM is sized for the proxy
    #     stack, not for N concurrent desktop sessions.
    #   - Lifecycle independence: redeploying Guac shouldn't kill all
    #     in-flight operator workspaces.
    workspaces = optional(object({
      enabled = optional(bool, false)
      # Size of the pre-spawned container pool. Each slot binds host
      # port 5900+i. Cap at 9 to keep the port range tidy (5901–5909).
      pool_size = optional(number, 4)
      # VM size. D4s_v4 (4 vCPU / 16 GB) comfortably fits 4 kali-rolling
      # containers + a browser. Bump to D8s_v4 for pool_size > 4.
      vm_size = optional(string, "Standard_D4s_v4")
      # When true, idle slots (no recent VNC client) auto-restart every
      # restart_interval_minutes for clean-state recycling. False keeps
      # containers up forever (debug mode).
      auto_restart         = optional(bool, true)
      restart_interval_min = optional(number, 30)
      }), {
      enabled              = false
      pool_size            = 4
      vm_size              = "Standard_D4s_v4"
      auto_restart         = true
      restart_interval_min = 30
    })
  })
}

variable "shared_machines" {
  description = "Hub-tier infrastructure boxes (Ghostwriter, SteppingStones, RedELK)."
  type = list(object({
    name           = string
    role           = string
    os             = string
    size           = string
    linux_user     = string
    linux_password = string
    # When false, this shared infra box has no public IP. Operators
    # reach it via Guacamole's internal-network SSH connection.
    public_ip = optional(bool, true)
  }))
  default = []
}

variable "advanced_c2" {
  description = "Optional Azure Front Door fronting per-student c2-redirector."
  type = object({
    enabled                  = bool
    domain                   = string
    dns_zone_resource_group  = string
    dns_zone_subscription_id = optional(string, "")
    cover_url                = string
    fdid_header_required     = bool
    student_subdomain_format = string
    endpoint_name            = optional(string, "")
    profile_name             = optional(string, "")

    # ── DoH (DNS-over-HTTPS) C2 leg ────────────────────────────────────
    # Per-C2 map of DoH stealth hostnames. When non-empty for a given C2,
    # terraform creates an additional AFD custom domain + route for that
    # hostname; nginx on the assigned redirector adds a `location
    # /dns-query` block that proxies DoH POSTs into a sidecar dnsdist
    # converter (DoH→raw DNS) → C2's DNS listener on internal :5353.
    # Beacons send DoH over HTTPS, so wire transport rides AFD anycast —
    # the C2's DNS listener IP is never publicly exposed.
    #   advanced_c2.dns_listeners = {
    #     sliver  = "<doh-customname-1>.enterprisesstudio.com"
    #     mythic  = "<doh-customname-2>.enterprisesstudio.com"
    #     adaptix = "<doh-customname-3>.enterprisesstudio.com"
    #     brc4    = "<doh-customname-4>.enterprisesstudio.com"
    #   }
    # MUST be a different FQDN from each C2's HTTPS AFD subdomain — DNS
    # protocol won't let one name be both a CNAME (HTTPS via AFD) and
    # an NS / route target with conflicting record types.
    dns_listeners = optional(map(string), {})

    # When true, DoH gets its OWN dedicated azurerm_cdn_frontdoor_profile
    # + endpoint instead of sharing the HTTPS C2 profile. Trade-off:
    #   false (default) — same AFD profile + endpoint; just extra custom
    #     domains + routes. ~$0 extra. Same anycast IP for both legs;
    #     differs only by SNI on the wire.
    #   true            — separate Front Door profile entirely.
    #     ~$35/mo extra (second profile is billed independently). Max
    #     isolation: different anycast IP, separate billing surface, and
    #     if the HTTPS profile is ever flagged/reported the DoH profile
    #     stays untouched.
    dns_dedicated_afd_profile = optional(bool, false)

    # Per-deploy custom header that nginx on each redirector requires
    # before forwarding to the C2 (both HTTPS C2 and DoH legs). Beacons
    # send this header on every callback; any request without the right
    # name+value falls through to the cover page → 302 to cover_url.
    # Empty token = check disabled (relies on fdid_header_required alone).
    # The token is a per-deploy shared secret — operator picks the value
    # and configures implants to send the same header.
    beacon_header_name  = optional(string, "X-Request-Id")
    beacon_header_token = optional(string, "")
  })
  default = {
    enabled                   = false
    domain                    = ""
    dns_zone_resource_group   = ""
    dns_zone_subscription_id  = ""
    cover_url                 = "https://www.microsoft.com"
    fdid_header_required      = true
    student_subdomain_format  = "{sid}"
    endpoint_name             = ""
    profile_name              = ""
    dns_listeners             = {}
    dns_dedicated_afd_profile = false
    beacon_header_name        = "X-Request-Id"
    beacon_header_token       = ""
  }
}

# How long `terraform apply` should block after AFD resources are created
# to give Azure time to validate the TXT records and issue managed certs.
# Real-world validation typically completes in 5–15 min; 20 min is the
# defensive default. Set to 0 to skip the wait and use `./range afd-status`
# to poll validation state yourself.
variable "advanced_c2_validation_wait_minutes" {
  type    = number
  default = 20
}

# Speed knob for ephemeral lab deploys. Trades latest CVE patches for
# 10-20 min off wall-time. When true:
#   - DC bootstrap disables wuauserv at script start (no Windows Update
#     on first boot — DC promo doesn't need it).
#   - windows-dc VM size bumps from D4s_v5 (4 vCPU) to D8s_v5 (8 vCPU)
#     so patching + AD promo run faster while they happen.
# Default false (production-safe).
variable "fast_windows" {
  type    = bool
  default = false
}

# Pre-baked image config. When enabled=true and a SIG version exists,
# Windows VMs deploy from the SIG image (which has AD-DS + WinRM + Win
# Update disabled pre-installed) instead of from Marketplace. Cuts
# deploy time by ~25-35 min per range. Operator runs `./range bake` to
# populate the gallery; until that completes, images.tf falls back to
# Marketplace automatically.
variable "baking" {
  type = object({
    enabled             = bool
    resource_group_name = optional(string, "terra-range-images-rg")
    gallery_name        = optional(string, "terra_range_images")
    # Per-OS "deploy FROM the baked image" toggles — deliberately
    # SEPARATE from `enabled`:
    #   enabled                    -> create the SIG gallery + image
    #                                 definitions (cheap; safe with
    #                                 nothing baked yet)
    #   use_baked_<os>             -> deploy VMs FROM the baked <os>
    #                                 image (requires a version to
    #                                 actually exist in the gallery)
    # They MUST be separate: data.azurerm_shared_image_version ERRORS
    # the whole apply when no version exists yet, and `try()` does NOT
    # catch a data-source read failure. Workflow:
    #   1. apply with enabled:true        -> gallery created, Marketplace
    #                                        images used
    #   2. ./range bake <os>              -> publishes an image version
    #   3. flip use_baked_<os>:true, apply -> deploys from the SIG image
    use_baked_kali              = optional(bool, false)
    use_baked_win_server_2025   = optional(bool, false)
    use_baked_win_server_2022   = optional(bool, false)
    use_baked_win_server_2019   = optional(bool, false)
    use_baked_win_10            = optional(bool, false)
    use_baked_win_11            = optional(bool, false)
    use_baked_elk               = optional(bool, false)
    use_baked_redelk            = optional(bool, false)
    use_baked_debian_redirector = optional(bool, false)
    use_baked_guacamole         = optional(bool, false)
    use_baked_adaptix           = optional(bool, false)
    use_baked_mythic            = optional(bool, false)
    use_baked_sliver            = optional(bool, false)
    use_baked_ghostwriter       = optional(bool, false)
    use_baked_stepping_stones   = optional(bool, false)
  })
  default = {
    enabled                     = false
    resource_group_name         = "terra-range-images-rg"
    gallery_name                = "terra_range_images"
    use_baked_kali              = false
    use_baked_win_server_2025   = false
    use_baked_win_server_2022   = false
    use_baked_win_server_2019   = false
    use_baked_win_10            = false
    use_baked_win_11            = false
    use_baked_elk               = false
    use_baked_redelk            = false
    use_baked_debian_redirector = false
    use_baked_guacamole         = false
    use_baked_adaptix           = false
    use_baked_mythic            = false
    use_baked_sliver            = false
    use_baked_ghostwriter       = false
    use_baked_stepping_stones   = false
  }
}

# Hub infra subnet — second /24 inside the hub /22.
variable "hub_infra_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# Shared-lab subnet inside the hub VNet, used by per_student=false target
# machines in MULTI-STUDENT shared-mode deploys (the "everyone attacks the
# same DC" shape). In single-student deploys this subnet is created but
# empty — costs nothing. In multi-student deploys dc01 / srv01 / ws10 /
# ws11 / linux01 / analyst (any machine with per_student: false) land
# here, peered to every per-student attacker spoke via the existing
# hub↔spoke peering, so every student's kali can reach them.
variable "hub_shared_lab_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

# CIDR plan
#   Hub  : 10.0.0.0/22  (mgmt 10.0.0.0/24, infra 10.0.1.0/24, shared-lab 10.0.2.0/24)
#   Sn   : 10.<n>.0.0/22 — targets 10.<n>.0.0/24, attacker 10.<n>.1.0/24
variable "hub_cidr" {
  type    = string
  default = "10.0.0.0/22"
}

variable "hub_mgmt_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

# ============================================================================
# Brute Ratel C4 license credentials.
# Empty defaults = "skip BRC4 install". The bootstrap script aborts cleanly
# when these are blank, leaving the rest of the range deployable.
# Passed in via TF_VAR_* by the ./range wrapper after prompting the operator.
# ============================================================================
variable "brc4_license_id" {
  type        = string
  default     = ""
  sensitive   = true
  description = "BRC4 License ID (issued with your Brute Ratel license)."
}

variable "brc4_activation_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "BRC4 Activation Key (issued with your Brute Ratel license)."
}

variable "brc4_email" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Email associated with your BRC4 license."
}

variable "brc4_blob_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional: pre-staged BRC4 archive SAS URL. Used as fallback if direct download from bruteratel.com fails."
}
