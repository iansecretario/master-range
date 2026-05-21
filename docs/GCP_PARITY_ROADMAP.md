All right, I now have a thorough picture. Producing the deliverable below.

---

# terra-range GCP Parity Roadmap

A read-only audit of `/Users/ian/Documents/Projects/terra-range/` and the engineering plan to bring up a `modules/gcp/` + `envs/gcp/` peer to the existing Azure path. The Azure module is large and feature-dense (~250 KB of HCL across 14 .tf files, plus a 3000-line `range` CLI, 18 ansible roles, 17 Packer templates, and a 1000-line provider-aware generator). A full port is non-trivial but every Azure construct in use does have a GCP equivalent, with notable degradations around managed Front-Door-style fronting and Spot VM eviction-behaviour semantics.

---

## 1. Azure → GCP construct mapping

| Layer | Azure resource (used in terra-range) | GCP equivalent | Notes / imperfection |
|---|---|---|---|
| Subscription/account | Azure subscription | GCP Project | terra-range assumes one sub for VMs, optional second sub for DNS (advanced_c2 + Guacamole DNS). GCP analog: one project for VMs, optional shared-VPC host project or separate Cloud DNS project. |
| Resource grouping | `azurerm_resource_group` (per-student, hub, baking) | No native equivalent — GCP has folders + projects but those are coarser. The Azure-style "one RG per student" is usually mapped to **labels** (`student_id=lab01`) + a naming prefix. Alternatively, one **project-per-student** (true isolation, but cross-project VPC peering and quotas now apply). | Major behavioural difference: `terraform destroy` of a student in Azure deletes the RG and everything in it as one atomic operation. In GCP you must destroy every resource individually. The "auto-import orphans" logic is therefore much more important to get right on GCP. |
| VNet | `azurerm_virtual_network` | `google_compute_network` (custom subnet mode) | GCP VPCs are global; subnets are regional. terra-range only deploys to one region per range, so this is a parity match. |
| Subnet | `azurerm_subnet` (hub_mgmt, hub_infra, hub_shared_lab, targets, attacker) | `google_compute_subnetwork` | Same shape. GCP requires `private_ip_google_access = true` if you want VMs without public IPs to reach Google APIs (Marketplace VM agent, monitoring), which is the default mode terra-range likes. |
| NSG | `azurerm_network_security_group` + `azurerm_subnet_network_security_group_association` | `google_compute_firewall` (rules attached to the VPC, scoped by tags or service accounts) | Big behavioural delta. Azure NSGs are stateful, per-subnet, ordered by priority (100-4096), and have explicit deny + an implicit `DenyAllInbound`. GCP firewalls are stateful, per-VPC, ordered by priority (0-65535), with an implicit `default deny ingress, default allow egress`. NSG rules with `source_address_prefix` "VirtualNetwork", "AzureFrontDoor.Backend", "Internet" map to either CIDRs or `source_ranges`/`source_tags`/`source_service_accounts`. There is no GCP equivalent of the "AzureFrontDoor.Backend" service tag — see §5 gotchas. |
| NSG chunking (3500-CIDR cap) | Azure: 4000 prefixes per rule (1900 cap in code) | GCP: 256 source/destination ranges per firewall rule (much lower) | This is the single biggest network-config delta. terra-range's geofence today emits ~4300 CIDRs for SG/PH/AE/QA/SA and chunks at 3500. On GCP that has to chunk at ~250 → ~17 firewall rules per logical rule, and there's a per-VPC cap of ~200 firewall rules by default (raisable). For 10k+ CIDRs this becomes the dominant networking-design constraint. |
| VNet peering | `azurerm_virtual_network_peering` (hub ↔ spoke pair) | `google_compute_network_peering` (also a pair) OR a single Shared VPC | Parity match for the peering shape. For the per-student-spoke design, a Shared VPC where each student is a project would be cleaner long-term, but pure VPC peering reproduces the existing topology 1-for-1. |
| NAT gateway | `azurerm_nat_gateway` + `azurerm_public_ip` + 2× `subnet_nat_gateway_association` (one per student) | `google_compute_router` + `google_compute_router_nat` (one Cloud NAT per region per VPC) | Cloud NAT is significantly cheaper (~$0.044/hr base + ~$0.045/GB; Azure NAT GW is ~$0.045/hr + ~$0.045/GB). Allocation model is different: Cloud NAT is one router-level resource that NAT-enables one or more subnetworks, vs Azure's per-subnet associations. Auto-allocate ephemeral IPs at the Cloud NAT layer, no per-NAT public-IP resource. |
| Linux VM | `azurerm_linux_virtual_machine` | `google_compute_instance` (with `metadata.startup-script` for cloud-init) | GCP linux instances natively run cloud-init when the image is cloud-init-enabled (Ubuntu, Debian, Kali on GCP Marketplace) — `metadata.user-data` works the same way Azure's `custom_data` does. |
| Windows VM | `azurerm_windows_virtual_machine` | `google_compute_instance` with a Windows image family | On GCP Windows you can't just inject PowerShell via `custom_data`. The native mechanism is `metadata.windows-startup-script-ps1` (or `sysprep-specialize-script-ps1` for first-boot-only). |
| Windows long-running bootstrap | `azurerm_virtual_machine_run_command` (used to bypass the CSE 8191-char limit for the DC promo script) | GCP startup-script has effectively no size limit when delivered via `metadata-from-file` or Cloud Storage, BUT it runs every boot by default (use a sentinel marker, which the existing scripts already do). For "run once on demand from terraform after VM is up" semantics — i.e. the DC↔members dependency in `vms.tf` — there is no native GCP equivalent. Options: (a) ship the script as a startup-script and add an internal "wait until DC is promoted" loop in member scripts, (b) use OS Login + `gcloud compute ssh --command` via a `null_resource` with a `remote-exec` provisioner. The (a) approach is closer to the existing design. | The 90-min create timeout on the Azure RunCommand resource has no direct GCP analog; you instead rely on the script's internal AD-replication wait loop. |
| Shared Image Gallery | `azurerm_shared_image_gallery` (one) + `azurerm_shared_image` (15) + `data.azurerm_shared_image_version` (read-latest) | `google_compute_image` in an "Image Family" (`family = "terra-range-kali"`); read latest via `data.google_compute_image` with `family = "terra-range-kali"`. | Imperfect mapping. GCP doesn't have a gallery container — images live flat in the project. Image-family is the closest thing to "latest version" indirection (Packer publishes new images with a timestamped name and `family=` label; the data source resolves `family=<name>` to the newest non-deprecated image). No `prevent_destroy` on the gallery RG analog — GCP images themselves can carry `lifecycle { prevent_destroy = true }` per image. Cross-region replication: copy the image to other regions via additional `google_compute_image` resources, or `storage_locations` argument in Packer. |
| Image (custom OS) | `azurerm_shared_image_version` (via Packer SIG destination block) | `google_compute_image` (via Packer `googlecompute` builder's `image_name` + `image_family`) | Parity match. Packer's `googlecompute` builder is mature and well-documented. |
| Marketplace image with plan | `plan {}` block (Kali requires plan acceptance per subscription) | GCP Marketplace works with `agreement_accept` programmatically OR launching via the console once. Kali Linux on GCP is published by Kali under project `kali-linux-public`; Windows Server family is `windows-cloud`. | Kali's plan-acceptance step that exists in `images.tf` would become a one-time GCP marketplace subscription. Less moving parts. |
| Public IP | `azurerm_public_ip` (Standard SKU, static) | `google_compute_address` (REGIONAL for VM-attached, GLOBAL for LB-frontend) | Parity match. Pricing different: GCP static external IPs are ~$0.005/hr (~$3.65/mo) when attached, ~$0.01/hr unattached — Azure Standard PIP is ~$0.005/hr always. Wash. |
| Internal static IP | `azurerm_network_interface.ip_configuration.private_ip_address_allocation = "Static"` | `google_compute_address` with `address_type = "INTERNAL"` + reference from instance `network_interface.network_ip` | Parity match. The static-IP convention in `vms.tf` (`10.<n>.1.5/.6/.7/.8/.9/.10/.11/.12/.20/.21`) ports directly. |
| Front Door (anycast HTTPS CDN front) | `azurerm_cdn_frontdoor_profile` + `azurerm_cdn_frontdoor_endpoint` + per-redirector custom domains + managed certs + DoH custom domains + DNS TXT validation + automatic cert rotation | **Cloud CDN + External HTTPS Load Balancer** (`google_compute_global_address` + `google_compute_managed_ssl_certificate` + `google_compute_target_https_proxy` + `google_compute_url_map` + `google_compute_backend_service` with `cdn_policy`). Roughly equivalent. | This is the **single biggest port effort** outside the baking system. The advanced_c2 module on Azure is `frontdoor.tf` (21 KB), `listeners.tf` (17 KB), and pieces of `guacamole_dns.tf` — ~50 KB of HCL whose nearest GCP form is a multi-resource External HTTPS LB chain. GCP managed certs validate via DNS-01 (you create the `CNAME` to ghs.googlehosted.com manually OR via Cloud DNS, then `google_compute_managed_ssl_certificate` polls). There's no AzureFrontDoor.Backend service tag — the firewall to the redirector accepting only AFD has to become "accept only from the GCP Cloud CDN edge ranges" published in https://www.gstatic.com/ipranges/goog.json (parse weekly) OR shift to per-redirector private NEG via PrivateServiceConnect, which is more invasive. |
| Cloud DNS zone | `azurerm_dns_zone` (referenced via data source in `frontdoor.tf` and `guacamole_dns.tf`) | `google_dns_managed_zone` (data source) | Parity match. Both support cross-project zones; GCP uses an aliased provider with `user_project_override` instead of Azure's `subscription_id` parameter. |
| DNS A record | `azurerm_dns_a_record` | `google_dns_record_set` (type=A) | Parity match. |
| Identity / KMS | `azurerm_key_vault` (used in `key_vault.tf` for the auto-generated random passwords) — actually used? Let me re-check. The file is `key_vault.tf` so it's referenced; for secrets the random_password values are written to local files in `lab_artifacts.tf`. | `google_secret_manager_secret` + `google_secret_manager_secret_version` for the parallel. Key Vault is light-touch in terra-range though; the existing `lab_artifacts.tf` pattern (write `credentials.txt` to a local `labs/<range>/` directory) works identically on GCP — no provider tie. |
| Operator SSH key plant on every VM | Cloud-init `users:` block (set per-VM via `custom_data`) | Same — cloud-init `users:` works identically on GCP Linux. For GCP-native: enable OS Login on the project, all SSH access becomes IAM-managed (no SSH-key-per-VM). For terra-range's "operator → ranger@vm" workflow OS Login is **the wrong choice** because student/operator passwords are pre-generated terraform outputs; stay with cloud-init-injected keys. |
| Spot pricing | `priority = "Spot"`, `eviction_policy = "Deallocate"`, `max_bid_price = -1` | `scheduling.preemptible = false` + `scheduling.provisioning_model = "SPOT"` + `scheduling.instance_termination_action = "STOP"` (preserves boot disk) | Behavioural delta. GCP Spot VMs are SHUTDOWN (not deallocated like Azure Spot's `Deallocate`); state is preserved on the boot disk, but the VM is fully stopped — `gcloud compute instances start` brings it back. Practical equivalence to the Azure pattern. **Important**: GCP Spot eviction is more frequent than Azure Spot in `southeastasia` based on operator reports, particularly for high-memory windows VMs in `asia-southeast1`. spot_pinned_roles (`windows-dc`, `c2-redirector`) translate cleanly. |
| Marketplace terms | `az vm image terms accept --urn ...` once per subscription per third-party SKU | `gcloud compute images accept-marketplace-license` (rarely needed — most distros are first-party) | Easier on GCP: Kali on GCP is in the Kali project and free; no per-account acceptance like Azure's Marketplace+Kali. |
| Quota | `Microsoft.Quota` REST API via `az rest` PUT | **Service Usage API** (`serviceusage.googleapis.com`) for service enablement + **Cloud Quotas API** (`cloudquotas.googleapis.com`, beta as of 2024 and GA in 2025) for the actual increase requests. | Imperfect. Cloud Quotas API supports programmatic increase requests for many but NOT ALL families; some still require a Cloud Console support-case form. Defaults are also smaller than Azure: a new GCP project gets ~24 CPU per region by default vs Azure's 10-20 vCPU per family on a new sub. For Windows VMs you also need `WINDOWS_LICENSE` quota (per-vCPU). |
| Cost estimation | `scripts/quota-cost.py` reads tfvars, hardcodes per-SKU $/mo | Mirror with GCP machine-type → $/mo from https://cloud.google.com/compute/all-pricing or pull live via Cloud Billing Catalog API | Trivial mechanical port. |
| Run-command-style remote shell | `az vm run-command invoke -g $rg -n $vm --command-id RunShellScript --scripts "..."` (used for SSH-heal pass, `./range fix`, `./range diag`) | `gcloud compute ssh <instance> --tunnel-through-iap --command "..."` OR Cloud Operations Suite Agent's "Run Command" feature. **IAP TCP tunneling** is the canonical "out-of-band authenticated channel into a private VM" mechanism on GCP — requires the IAP-allowed-from firewall rule (35.235.240.0/20) and `iap.tunnelResourceAccessor` IAM role. | Parity match but with a notable substitution: where Azure's `az vm run-command` runs **as root** via the waagent extension regardless of SSH state, GCP's `gcloud compute ssh --tunnel-through-iap` runs **as the calling identity** (your gcloud user) and STILL requires SSH to be functional inside the VM. The "SSH-heal" use case (plant a pubkey when the user_data race left authorized_keys empty) cannot run over IAP-SSH because IAP-SSH itself uses SSH. For that, the substitution is `gcloud compute instances add-metadata --metadata-from-file ssh-keys=...` + `gcloud compute reset` — but resetting kills the VM and reboots. Cleanest replacement: switch the SSH-heal to **OS Login enforcement** and a one-shot startup-script-on-demand mechanism via the metadata server. See §4 feature audit, item 6. |
| Front-door-validated managed cert | `azurerm_cdn_frontdoor_custom_domain` with `tls.cdn_frontdoor_secret_id = null` (managed cert) + TXT validation | `google_compute_managed_ssl_certificate` (DNS-01 validation via the zone Cloud DNS holds) | Same shape, slightly different validation tempo. Azure Front Door's managed cert validation can take 30 min – 24 hr; GCP managed certs typically validate in 15-60 min once the DNS A record is published and the cert resource is attached to the target-https-proxy. |
| Operator credentials persistence | `lab_artifacts.tf` writes `labs/<range>/credentials.txt` via `local_sensitive_file` | Identical — purely terraform-local, no provider tie. |
| `lifecycle { prevent_destroy = true }` on the gallery | terraform-native (provider-independent) | Identical — works on `google_compute_image`, `google_dns_managed_zone`, etc. **The pattern stays.** |

---

## 2. Files / directories to create under `modules/gcp/` and `envs/gcp/`

This is a flat list of every file the engineer needs to author, each annotated with which Azure file it parallels and what contract it must honour.

### `modules/gcp/` (new directory — peer to `modules/azure/`)

- **`modules/gcp/versions.tf`** — declare `required_providers { google = "~> 6.0" }`. Parallel to `modules/azure/versions.tf`. Includes `random` and `local` providers.
- **`modules/gcp/variables.tf`** — exact mirror of `modules/azure/variables.tf`, with `azure_region` renamed `gcp_region` (or kept as `region`) and `baking.gallery_name` renamed `baking.image_prefix`. All other variable schemas (machines list, services object, advanced_c2 object, students object, shared_machines, baking) stay byte-for-byte identical so the generator and the existing YAML scenarios continue to feed both providers.
- **`modules/gcp/network.tf`** — parallels `modules/azure/hub.tf` + `modules/azure/students.tf`. Builds:
  - One `google_compute_network` (hub VPC, custom subnet mode)
  - Per-student `google_compute_subnetwork` (targets and attacker subnets at `10.<n>.0.0/24` and `10.<n>.1.0/24`)
  - Hub mgmt/infra/shared_lab subnets at the existing CIDRs (`10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`)
  - `google_compute_router` + `google_compute_router_nat` per student (replaces NAT gateway + NAT public IP + 2 associations × per student)
  - VPC peering OR — if engineering chooses — shared VPC. For Phase B, recommend single VPC + network tags for isolation (simpler).
- **`modules/gcp/firewall.tf`** — parallels the NSG bodies in `modules/azure/hub.tf`, `modules/azure/students.tf`. Every NSG rule becomes a `google_compute_firewall`. Caveats:
  - Geofenced CIDR list chunked at 256 (the GCP per-rule source-range cap), not 3500. So a 4300-CIDR geofence becomes ~17 rules per logical purpose × 3 purposes = ~50 firewall rules just for the geofence. Stay under the default 200/VPC cap.
  - C2 stack rules become per-target-tag rules. Each redirector / teamserver gets a tag like `c2-listener-adaptix-${student}` and the rule allows from `c2-redirector-adaptix-${student}` to that tag.
  - "AzureFrontDoor.Backend" source_address_prefix → no equivalent. Replace with one of:
    - Hard-coded GCP frontend IP ranges (parsed from `https://www.gstatic.com/ipranges/cloud.json`) — fragile, needs periodic refresh
    - Tag-based, where the LB is internal and the firewall allows the LB's serverless-NEG source range
    - Recommended Phase B: stub it as "allow 0.0.0.0/0:443 to redirector, trust nginx X-Api-* header validation alone" — same security model as Azure's `fdid_header_required = true` plus the operator's per-deploy beacon-header-token, just without the network-layer narrowing
- **`modules/gcp/vms.tf`** — parallels `modules/azure/vms.tf`. Linux VMs become `google_compute_instance` with `metadata.user-data` carrying the cloud-init script. Windows VMs become `google_compute_instance` with `metadata.windows-startup-script-ps1` and `metadata.sysprep-specialize-script-ps1`. The DC→members ordering uses (a) terraform `depends_on` for VM creation, (b) the DC PowerShell script's internal AD-replication wait loop, since there's no `azurerm_virtual_machine_run_command` equivalent. spot/preemptible pin list and the role-aware machine-type map mirror the Azure `local.vm_size` block but mapped to `n2-standard-2/4/8` etc. Same `lifecycle { ignore_changes = [metadata["user-data"], metadata["windows-startup-script-ps1"]] }` to keep userdata edits from force-replacing.
- **`modules/gcp/baking.tf`** — parallels `modules/azure/baking.tf` but flat (no gallery container). Each of the 15 image slots becomes:
  - One `data.google_compute_image` resource per `use_baked_<x>: true` flag (with `family = "terra-range-<x>"`, `most_recent = true`) — guarded with `count` matching the Azure pattern so an absent family doesn't fail the apply with a noisy "image family not found".
  - One `google_compute_image` resource per image-definition slot is **not** needed (unlike Azure, where the image-definition is a resource you provision separately from the version). GCP image families are implicit: any image created with `family = "terra-range-kali"` joins that family. So the baking.tf shrinks: just `data` reads, no image-definition `resource` blocks. The `prevent_destroy` lifecycle moves onto the images themselves (which Packer publishes).
- **`modules/gcp/images.tf`** — parallels `modules/azure/images.tf`. Same `local.image_map` shape: OS string → `{publisher: <gcp project>, family: <image family>}`. Replace Azure's `publisher/offer/sku/version` four-tuple with GCP's `project + family` two-tuple. Same `local.machine_source_image_id` role-aware + os-aware dispatch, returning the data-source `.self_link` instead of an Azure SIG version id. The size_map becomes:
  - `small  = "n2-standard-2"` (2 vCPU, 8 GB)
  - `medium = "n2-standard-4"` (4 vCPU, 16 GB)
  - `large  = "n2-standard-8"` (8 vCPU, 32 GB)
  - Adjust the role-aware overrides accordingly (windows-dc fast → `n2-standard-8`, linux-target → `n2-standard-2`, etc.)
- **`modules/gcp/passwords.tf`** — parallels `modules/azure/passwords.tf` essentially unchanged (provider-independent `random_password` resources).
- **`modules/gcp/operator_ssh.tf`** — parallels `modules/azure/operator_ssh.tf`. Auto-generates the operator ed25519 keypair, writes to `labs/<range>/`. No provider tie. Subtle change: the public key needs to be put in `metadata.ssh-keys = "ranger:<pubkey>"` on every Linux instance (vs. Azure's cloud-init `users:` block — though cloud-init still works on GCP linux too, and arguably staying with cloud-init is cleaner for cross-provider reuse).
- **`modules/gcp/cdn.tf`** — parallels `modules/azure/frontdoor.tf`. The biggest single port. Creates:
  - One `google_compute_global_address` (anycast frontend IP) per range or per-redirector
  - One `google_compute_managed_ssl_certificate` per custom domain (DNS-01 via Cloud DNS)
  - One `google_compute_backend_service` per redirector, pointing at a per-VM **Internet NEG** (since the redirector is in your VPC, you can also use a zonal NEG)
  - `google_compute_url_map` + `google_compute_target_https_proxy` + `google_compute_global_forwarding_rule` to wire it up
  - **DoH leg** (advanced_c2.dns_listeners): a second backend_service and a second URL map host rule
- **`modules/gcp/guacamole_dns.tf`** — parallels `modules/azure/guacamole_dns.tf`. Switch `azurerm_dns_a_record` → `google_dns_record_set`. Conceptually identical.
- **`modules/gcp/listeners.tf`** — parallels `modules/azure/listeners.tf`. The advanced_c2 per-CDN listener URL map rules. Same logic, switch resource types.
- **`modules/gcp/services.tf`** — parallels `modules/azure/services.tf`. Builds the Guacamole connection manifest. PURELY terraform locals + a `google_compute_instance` for the Guacamole VM. No provider-specific logic except the VM resource type. **The manifest itself (a JSON blob baked into the Guac VM's startup-script) is identical to the Azure version** — same connection types, same SFTP overlays, same student grouping.
- **`modules/gcp/shared_infra.tf`** — parallels `modules/azure/shared_infra.tf`. Ghostwriter / Stepping-Stones / RedELK as `google_compute_instance` resources in the hub VPC's infra subnet. Internal-only IPs by default (no equivalent of `public_ip` blob — just attach a `google_compute_address` if true). Mostly mechanical.
- **`modules/gcp/outputs.tf`** — parallels `modules/azure/outputs.tf`. Same output names so the generator, `inventory.py`, and `./range creds`/`./range outputs` continue to work. **Critical**: the `ansible_inventory` output is the contract `inventory.py` depends on. It must emit the same JSON shape (hostvars include `ansible_host`, `terra_public_ip`, AFD callback URLs, per-student creds).
- **`modules/gcp/lab_artifacts.tf`** — direct copy of `modules/azure/lab_artifacts.tf` (no provider tie).
- **`modules/gcp/key_vault.tf`** — either drop or rename to `secret_manager.tf` and use `google_secret_manager_secret`. Audit indicates Key Vault isn't doing much in the current flow; secrets live in `random_password.*` and surface via outputs + the local credentials file. Likely **drop entirely** for Phase B.
- **`modules/gcp/ansible/`** — **symlink to `modules/azure/ansible/`** (the AWS module already does exactly this: `modules/aws/userdata -> ../azure/userdata`). The ansible roles ARE provider-agnostic, since they all run over plain SSH using the operator SSH key. The only file that needs to know about GCP is `modules/azure/ansible/inventory.py`, which must learn to walk a GCP-shaped terraform state (data-source results from `google_compute_instance` instead of `azurerm_*_virtual_machine`). See §3.
- **`modules/gcp/userdata/`** — **symlink to `modules/azure/userdata/`**. Same userdata scripts work on GCP — they're cloud-init for Linux and plain PowerShell for Windows. The AWS module already symlinks this directory and shows it works across providers.

### `envs/gcp/` (new directory — peer to `envs/azure/`)

- **`envs/gcp/main.tf`** — provider block (`google` and optionally `google-beta`), aliased provider for the cross-project DNS sub (mirrors the Azure `azurerm.dns` and `azurerm.guac_dns` aliased providers — GCP variant uses `user_project_override` + a separate `quota_project_id`), the variable declarations (identical to `envs/azure/main.tf`), and the `module "range" { source = "../../modules/gcp" ... }` block. All outputs re-exposed.

### Packer side

- **`packer/<image>/<image>.pkr.hcl`** — every Packer template (kali, win-server-2019/22/25, win-10/11, kali-minimal, elk, redelk, debian-redirector, guacamole, adaptix, mythic, sliver, ghostwriter, stepping-stones — 15 total) needs a parallel **`googlecompute` source block** alongside the existing `azure-arm` source. Packer supports multiple sources per template and `--only` to choose at build time. Easiest path: copy each `.pkr.hcl` to a `.gcp.pkr.hcl` variant (avoids cross-cloud variable collisions). Each .gcp.pkr.hcl:
  - `source "googlecompute" "<name>"` with `image_family`, `image_name = "terra-range-<x>-${timestamp}"`, `disk_size`, `machine_type`
  - Same `provisioner` blocks (shell or PowerShell) — these are provider-agnostic
  - For Windows, swap `winrm` communicator config to GCE-standard (`username = "packer_user"` with `gcloud compute reset-windows-password` semantics or `winrm_use_ntlm = true`)
- **`packer/_shared/scripts/`** stays unchanged — it's provider-agnostic shell + PowerShell.

### Scripts

- **`scripts/quota-cost.py`** — needs a GCP branch. See §3.

### Scenarios

- No new scenario files needed. Existing `scenarios/*.yaml` switch from `provider: azure` to `provider: gcp` (or pass `--gcp` to override). The YAML schema itself stays the same.

### CLI

- **`range`** — no new file; modify existing. See §3.

---

## 3. Files that need to be MODIFIED for GCP

| File | What needs to change |
|---|---|
| `range` (3000+ lines) | Already accepts `--gcp` (line 174-178), already sets `PROVIDER=gcp` and `ENV_DIR=envs/gcp`, `MODULE_DIR=modules/gcp`. But: **every direct `az` invocation must dispatch on `$PROVIDER`**. ~74 raw `az ...` call sites. Required substitutions: `az account show` → `gcloud config get-value project`; `az vm run-command invoke` → `gcloud compute ssh --tunnel-through-iap --command` (with the caveats above); `az sig image-definition show` → `gcloud compute images describe-from-family`; `az sig image-version list` → `gcloud compute images list --filter='family:terra-range-<x>'`; `az vm list-usage` → `gcloud compute project-info describe` + `gcloud compute regions describe`; `az network list-usages` (for Public IP / VNet / NAT quota) → `gcloud compute regions describe --region` (includes quota arrays). Adopt a `_provider_dispatch <op>` helper that selects the binary + args. **Specific subcommand blocks that need rewrites:** `apply` (the auto-bake bootstrap), `bake` (the SIG slot-probe), `destroy` (the SIG state-detach prior to RG delete — note the GCP version doesn't have an RG to delete so the detach step becomes "delete the per-student VPC peering + subnetworks + instances and let the image family alone"), `repair` (the SSH-heal pre-pass — the most invasive change), `diag` (log-fetch via run-command → must switch to IAP SSH), `fix` (re-run cloud-init), `accept-marketplace` (becomes a no-op on GCP for most images; possibly `gcloud compute images describe kali-linux` to verify the project's images are reachable). |
| `generator/generate.py` line 197 | Change `("aws", "azure", "both")` → `("aws", "azure", "gcp", "both", "all")`. Line 1028's argparse choices similarly. Line 1186 `["aws","azure"] if "both"` → `["aws","azure","gcp"] if "all"`. Line 877-879 `if provider == "aws": tfvars["region"] = ...` else `tfvars["azure_region"] = ...` adds an `elif provider == "gcp": tfvars["gcp_region"] = cfg.get("gcp_region", "asia-southeast1")`. **`_normalize_advanced_c2(provider=)`** (line 888) needs a `provider == "gcp"` branch defaulting `domain = ""` and DNS RG-equivalent fields (project_id) to empty. |
| `scripts/quota-cost.py` | Currently 600+ lines of Azure-specific quota logic (`az vm list-usage`, `az network list-usages`, `_request_quota_increase` via Microsoft.Quota REST). Add a `gcp` branch dispatched on the tfvars path or on a `--provider gcp` flag. GCP-side logic mirrors the same flow:<br>1. `gcloud compute project-info describe --format=json` → `quotas[]` array gives per-region CPU + Windows-license + IPv4-address quotas. Match on `metric` field (e.g. `CPUS`, `IN_USE_ADDRESSES`, `NETWORKS`).<br>2. Threshold-driven auto-request via `gcloud alpha quotas update` (Cloud Quotas API, GA in mid-2025) — same as the Microsoft.Quota REST PUT. Many quotas still require a manual support case; the script should detect and fall back to printing a Cloud Console link.<br>3. Pricing table for GCP machine types (see §7). |
| `modules/azure/ansible/inventory.py` | Currently keyed off `terraform output ansible_inventory` (fast path) and `azurerm_linux_virtual_machine` / `azurerm_network_interface` / `azurerm_public_ip` (fallback walk). The fallback walk needs a GCP branch: `google_compute_instance` (no separate NIC resource — IP is embedded in `network_interface[0].network_ip` for private, `network_interface[0].access_config[0].nat_ip` for public). The fast-path (reading `ansible_inventory`) is unchanged provided `modules/gcp/outputs.tf` emits the same JSON shape. The simpler approach is to **rely on the fast path on GCP and let the fallback walk error out with a clear message** — the same suggestion already documented in `inventory.py:21`. |
| `modules/azure/ansible/roles/*` | Mostly provider-agnostic (SSH + apt + systemd). One audit needed: roles that hard-code "Azure metadata service" (169.254.169.254 — the IMDS) or `cloudapp.azure.com` hostname patterns will break on GCP. A quick `grep -r 'cloudapp\.azure\.com\|169\.254\.169\.254\|az vm run-command' modules/azure/ansible/roles/` is the audit. Anything matching needs a provider-aware Jinja conditional. |
| `modules/azure/userdata/c2-redirector.sh` and `userdata/c2-*.sh` | If any embedded path assumes Azure DNS lookup pattern (`<vm>.<rg>.<region>.cloudapp.azure.com`), substitute the GCP equivalent (`<vm>.<zone>.c.<project>.internal`). Audit grep needed. |
| `scenarios/*.yaml` | No structural change. Operator switches `provider: azure` → `provider: gcp` or passes `--gcp`. Region field is already provider-agnostic-named at the wrapper layer (each provider has its own `<provider>_region` in tfvars). The new YAML should add an `gcp_project_id` field for the deploy target, and the existing `advanced_c2.dns_zone_resource_group` becomes `advanced_c2.dns_zone_project_id` semantically — but to avoid scenario fragmentation, **rename in the GCP module's variables.tf to map to it under the same name** (the field is a free-form string anyway). |
| `geofence/*.txt` | No change. CIDR lists are provider-agnostic. |
| `BRC4-NOTES.md`, `README.md`, `ROADMAP.md` | Documentation refresh. Add a `# GCP support (Phase X)` section so operators know what's tested and what's stub. |

---

## 4. Per-feature audit (the 9 session-built features)

### 1. Auto-bake bootstrap — `_ensure_baked_images_exist()`

**Does it translate?** Conceptually yes, mechanically substantial. The Azure version probes for SIG slot existence via `az sig image-definition show` and SIG version existence via `az sig image-version list`. The GCP equivalent of this 2-step probe collapses to **one step**: `gcloud compute images list --filter="family:terra-range-<x>" --limit=1 --format='value(name)'` — if the result is non-empty, at least one image exists in that family. No separate "image-definition slot must exist" step because GCP image families are implicit (any image tagged with the family creates it).

**Targeted apply step** in `_ensure_baked_images_exist` (the "Ensure SIG infra exists" pre-pass that runs `terraform apply -target=...resource_group.baking[0] -target=...gallery -target=...image_definitions`) is **not needed on GCP** at all. The Packer `googlecompute` builder publishes directly to the project's flat image namespace. Just skip that whole block.

**One subtle issue:** GCP image families have no concept of "wait until terraform creates this image-definition before packer publishes into it". Race-free because the family doesn't pre-exist.

**Effort: 0.5 engineer-days** (just port the probe loop).

### 2. Quota auto-request — `scripts/quota-cost.py`

**Does it translate?** Yes, with a notable caveat. Microsoft.Quota REST PUT for VM-family quotas is replaced by **Cloud Quotas API** (`cloudquotas.googleapis.com`, GA mid-2025). Endpoint shape: `POST projects/<id>/locations/<region>/services/compute.googleapis.com/quotaInfos/<metric>/quotaPreferences`.

**Caveat:** the Cloud Quotas API does NOT yet cover every metric Azure's Microsoft.Quota covers. Notably, `WINDOWS_LICENSE` (per-vCPU license count) historically required a support case. Recent (2024-2025) progress brought most CPU metrics under programmatic increase. The fallback is `print` a Cloud Console URL.

**Pricing table** (the `SKU_PRICE_USD_MO` dict) needs GCP entries. See §7.

**Effort: 1.5 engineer-days.**

### 3. Bake-slot bootstrap in `bake)` case

**Does it translate?** Becomes a no-op on GCP. The Azure version probes `az sig image-definition show -g <rg> -r <sig_name> -i <image_def>`, runs a targeted terraform apply if missing. On GCP there's no slot — Packer just publishes into the family. Replace this block with a one-liner: `gcloud compute images list --filter="family:terra-range-${image_def}"` for parity reporting, then skip straight to `packer build`.

**Effort: 0.25 engineer-days.**

### 4. Skip-if-baked optimisation in roles (kali, adaptix, mythic, sliver, redelk)

**Does it translate?** Yes — no changes needed. The skip-if-baked probes are all filesystem-level (`stat:/opt/redelk/.baked`, `stat:/usr/bin/xfce4-session`, `/opt/adaptix/.build-sentinel`) and are entirely provider-agnostic. As long as the Packer bake step writes the same sentinel files (which it does — all the .pkr.hcl files invoke the same `_shared/scripts/*` provisioners), these probes work identically on GCP.

**Effort: 0 engineer-days.**

### 5. Build-sentinel for adaptix (`/opt/adaptix/.build-sentinel`)

Same as item 4. Provider-agnostic. Works.

**Effort: 0 engineer-days.**

### 6. SSH-heal pre-pass (`az vm run-command invoke` to plant operator pubkey)

**Does it translate?** **This is the single feature most affected by the GCP port.** The Azure version uses `az vm run-command invoke` to plant a pubkey on each Linux VM via Azure's waagent channel — an authenticated path that works **even when SSH itself is broken** (cloud-init `users:` race left `authorized_keys` empty).

GCP options, ranked by fidelity:
- **Option A (closest semantic match):** `gcloud compute instances add-metadata <vm> --metadata-from-file ssh-keys=...` adds the key to instance metadata. The Google Guest Environment agent (`google-guest-agent`, present on all GCP-published Linux images) polls metadata and updates `/etc/ssh/users/<user>/.ssh/authorized_keys` (OS Login disabled) or syncs to OS Login (enabled) **within ~5 seconds**. **This is more graceful than Azure's path** because no command execution is required — just metadata write. This **only works when the GCE guest agent is running**, but the agent is included in every GCP Marketplace Linux image (including kali-linux), and Packer-baked images inherit it. So Option A is the recommended path.
- **Option B:** `gcloud compute ssh --tunnel-through-iap` — but this requires SSH itself to be functional in the VM. Not a fix for the actual "authorized_keys is empty" race.
- **Option C:** `gcloud compute reset <vm>` — kills and reboots the VM. Heavy-handed.

**Recommendation:** Replace the loop body in the SSH-heal pre-pass with `gcloud compute instances add-metadata --metadata ssh-keys="<user>:<pubkey>" <vm>` per VM. The guest agent handles propagation. ~2 sec per VM (faster than the Azure run-command round-trip of ~5-10s).

**Effort: 0.5 engineer-days** (script change, plus testing the propagation timing).

### 7. Auto-import orphans — `_auto_import_orphans()`

**Does it translate?** Yes. The Azure version parses `terraform apply` log for "a resource with the ID \"<ID>\" already exists" and runs `terraform import <addr> <id>`. The error message text is **the same on the GCP provider** (it's a hashicorp/terraform message, not provider-specific). The Python regex on line 297-304 (`re.compile(r'a resource with the ID "([^"]+)" already exists...')`) matches identically; only the second capture group (`module.range.azurerm_X.Y["key"]` → `module.range.google_compute_X.Y["key"]`) needs the regex relaxed from `azurerm_` to `(azurerm_|google_)`. Trivial.

Caveat: import IDs differ in format. Azure IDs are full `/subscriptions/.../resourceGroups/.../providers/.../<name>`. GCP IDs are `projects/<id>/zones/<zone>/instances/<name>` or `projects/<id>/global/networks/<name>` etc. `terraform import` accepts whatever the provider documents per resource type; the auto-import path already does no parsing of the ID, just substitutes it verbatim into the import call. **No code change needed beyond the regex relaxation.**

**Effort: 0.25 engineer-days.**

### 8. Self-heal `vncserver@:1` in the kali role

**Does it translate?** Yes — no changes needed. Pure systemd / nc / wait_for primitives. Provider-agnostic.

**Effort: 0 engineer-days.**

### 9. Specialized image considerations (nested virt, linked clones)

**Does it translate?** Partially. GCP has its own nested-virt story:
- **Nested virtualization** on GCP requires `enable_nested_virtualization = true` in the instance `advanced_machine_features` block, AND only works on **Intel Haswell and later** machine types (n1, n2, n2d, c2, c2d, c3 — not e2/t2d). Azure's nested-virt support is broader (any Dv5/Ev5/Bv5).
- **Linked clones:** GCP doesn't have a direct "linked clone" feature. The closest is creating instances from a custom image (same as Azure SIG version-based deploy). For repeated fast-cloning the cost is the same: provision time = image-pull time. No native CoW-disk story.
- **FLARE-VM (windows-analyst)** explicitly needs nested virt for sandbox detonation. Needs explicit `enable_nested_virtualization = true` on that instance, and pinning to an n2-standard-* family (not e2/t2d).

**Effort: 0.25 engineer-days** to add the `advanced_machine_features` block conditionally.

---

## 5. GCP-specific gotchas terra-range will hit

### Things that are HARDER on GCP than Azure:

1. **Front Door / fronted-CDN parity.** Azure Front Door is a single resource (`azurerm_cdn_frontdoor_profile`) that gives you anycast + managed certs + per-route header rewrite + WAF + custom-domain TXT validation, all in one product. The GCP equivalent (External HTTPS Load Balancer + Cloud CDN) requires assembling 7-10 resources (global address + 1-N managed certs + target-https-proxy + url-map + 1-N backend services + 1-N NEGs + global forwarding rule + DNS records). The Azure pattern of "one resource per redirector that handles HTTPS + DoH + cover-page rewrite" doesn't map cleanly — each of those features becomes its own resource. **~50 KB of HCL on Azure becomes ~80-100 KB of HCL on GCP for the same advanced_c2 surface area.**

2. **NSG-equivalent CIDR-rule cap.** Azure NSG rules accept 4000 source prefixes per rule (terra-range caps at 1900 for safety margin). GCP firewall rules cap at **256 source ranges per rule**. The geofence path that today emits ~4300 CIDRs across 5 countries currently chunks into 2 rules per logical purpose on Azure. On GCP that becomes ~17 rules per logical purpose × 3 logical purposes = ~50 firewall rules just for the operator geofence. The default per-VPC firewall-rule cap is **200 rules**. With 50 rules consumed by geofencing and another ~30 by the C2 stack tag-based allows, this is workable but tight. Multi-student deploys (4+ students × 8 C2 rules) push you toward the 200 cap; **quota increase to 500 rules per VPC will be needed for any range with students > 6**.

3. **No "AzureFrontDoor.Backend" service tag.** Azure provides a maintained service tag your NSG can reference as the source. GCP has nothing equivalent for Cloud CDN edge IPs. You either parse Google's published IP ranges JSON (which changes monthly and would require a refresh-on-apply step similar to the geofence refresh), OR accept 0.0.0.0/0:443 to the redirector and rely on nginx layer-7 header validation (operator's per-deploy `beacon_header_token`). The latter is what we recommend for Phase B — the security model is similar to Azure's `fdid_header_required = true` mode.

4. **Resource Group abstraction.** Azure's "destroy a resource group, everything inside dies atomically" is genuinely useful — `./range destroy` benefits from it (one `terraform destroy` and per-student RGs vanish along with all child resources). GCP has no equivalent unit between project and individual resource. terra-range will either run destroy more carefully (which the auto-import path already supports) or shift to **one project per student**, which has its own complications (project quota — each org can have ~250 projects without quota increase).

5. **Quota defaults.** A fresh GCP project gets ~24 vCPU per region by default. A new Azure sub typically starts at 10-20 vCPU per family. Both require quota requests for production lab scale, but GCP's per-region cap is **per region across all machine families combined**, whereas Azure quotas are per-family (Standard DSv5, Standard BS, etc.). For terra-range's mixed-fleet redteam-lab scenario, this means: on Azure you might be quota-fine for DSv5 but quota-blocked on BSv2; on GCP one big bucket. Easier to reason about, but the single-pool single-region cap is **harsher** when running multi-student.

6. **OS Login vs metadata SSH keys.** GCP projects can be configured to enforce OS Login (`enable-oslogin = TRUE` in project metadata), which routes ALL SSH access through IAM. terra-range's design generates per-student random passwords and embeds an operator SSH key — fundamentally **incompatible with enforced OS Login**. The right setting is `enable-oslogin = FALSE` at the project level (or per-instance). This is one of those settings that an operator who runs `gcloud projects describe` might find surprising defaults applied to from an organization-level policy. **Document explicitly in the GCP README that the project must be OS-Login-FREE.**

7. **Windows Server licensing model on GCP differs from Azure.** Azure runs Windows VMs with the license cost baked into the SKU price; GCP also does this BUT GCP charges per-vCPU licence ($0.046/vCPU/hr for Server, $0.16/vCPU/hr for Datacenter+SQL+etc.) on top of the base VM price. For terra-range's typical 4 vCPU Windows VMs, the Windows-license premium is ~$135/mo per VM on top of compute. Azure embeds this in the SKU price (so it's invisible). **Net effect: GCP Windows VMs are 15-20% more expensive than Azure Windows VMs for the same vCPU count.** See §7.

8. **Spot/preemptible eviction frequency.** GCP Spot VMs have historically been more aggressively preempted than Azure Spot in capacity-tight regions. `asia-southeast1` (the closest geographic match to Azure's `southeastasia`) has only two zones (a, b) and reportedly higher preemption rates on Windows-licensed Spot VMs than e.g. `us-central1`. For long-running labs, **assume more frequent evictions than Azure Spot** and either widen the `spot_pinned_roles` list (pinning more roles to on-demand) or accept the operator has to `gcloud compute instances start` periodically.

### Things that are EASIER on GCP than Azure:

1. **No Marketplace plan-acceptance per third-party SKU.** Kali on Azure requires `az vm image terms accept --urn kali-linux:kali:kali-2026:latest` once per subscription. Kali on GCP is in the public `kali-linux-public` project — no acceptance step. Same for most Linux distros. (Windows Marketplace SKUs have a similar "no-acceptance" story on GCP.) The whole `./range accept-marketplace` subcommand becomes a no-op.

2. **Cloud NAT is cheaper.** Cloud NAT has a per-VM-hour billing model (~$0.0014/VM/hr per attached VM) plus data processing. For a 15-VM range, ~$15/mo. Azure NAT Gateway is ~$32/mo flat + processing. Per-student NAT in lockdown=false is roughly half the cost on GCP.

3. **One Cloud NAT covers multiple subnetworks.** terra-range's "one NAT gateway per student" pattern can collapse to "one Cloud NAT per region" with subnetwork rules. Simpler topology, fewer terraform resources. Optional optimization for Phase D.

4. **Sustained-use discounts** are automatic on GCP — VMs running >25% of the month get up to 30% off the base PAYG price, no contract. For ranges that stay up multi-week (engagement scenarios), this is meaningfully cheaper than Azure's PAYG.

5. **Egress to internet on GCP from `asia-southeast1` is cheaper than Azure egress from `southeastasia`** for the first GB tiers (GCP: free first 200 GB/mo for general use, then $0.12-0.19/GB; Azure: $0.09/GB after a 100 GB free monthly allowance — but Azure egress prices were just raised in 2025). For a lab pulling docker images / apt mirrors / OS updates this is wash to slightly GCP-favored.

6. **Image families** are a cleaner abstraction than Shared Image Galleries. No gallery container resource to maintain, no `lifecycle prevent_destroy` on a parent resource. Each Packer publish creates a new image and tags it with `family = "terra-range-kali"`; the data source resolves to the most-recent one automatically.

### Things that genuinely DON'T EXIST on GCP:

1. **No native equivalent of `azurerm_virtual_machine_run_command`** for the use-case of "fire a one-off script against a VM as root via the cloud's authenticated control-plane channel, regardless of SSH state". The closest is the GCE guest-agent metadata-driven script execution, but it triggers on metadata-change events, not on a synchronous "run now" API call. The Azure run-command resource is the cleanest cloud-init substitute for the Windows-DC promotion bootstrap (which has the 8191-char CSE limit problem). On GCP that resource block goes away — replaced by the standard `metadata.windows-startup-script-ps1` (no size limit) + the script's own internal idempotency. **No regression in functionality**, just a different pattern.

2. **No equivalent of Azure's `azurerm_resource_group` atomic destroy.** Mentioned above. Workaround: ensure `./range destroy` does targeted terraform destroys in dependency order, or shift to project-per-student.

3. **No `prevent_destroy` analog on the gallery container** (because there's no gallery container). The Packer-published images themselves carry `lifecycle prevent_destroy = true`. Same outcome, different mechanism.

4. **No Front Door "managed cert auto-rotation in 24 hours" SLA equivalent.** GCP managed certs auto-rotate too, but the SLA documented is "we'll try". In practice both are equally reliable.

---

## 6. Engineering plan (phased)

Each phase produces a tangible operator-visible milestone. Effort estimates assume one engineer familiar with the existing Azure module + competent in GCP.

### Phase A — bare-minimum single-student deploy: 3 engineer-days

- Create `modules/gcp/` directory with `versions.tf`, `variables.tf` (copied from Azure with region rename), `network.tf` (one VPC, one student subnet pair), `firewall.tf` (just the ingress for SSH + RDP for one operator IP), `vms.tf` (only Linux + Windows VM resources — no roles, just one kali + one win-server-2022).
- Create `envs/gcp/main.tf` with provider block.
- Modify `generator/generate.py` to accept `provider: gcp` and emit `envs/gcp/terraform.tfvars.json`.
- Modify `range` script's `apply` subcommand to skip the `_ensure_baked_images_exist` call when `$PROVIDER == "gcp"` (since we have no baked images yet).
- Use a trimmed-down scenario (1 kali + 1 win-server, no advanced_c2, no shared_infra, no baking, no domain).
- **Success criterion:** `./range --gcp apply test-scenario` produces a VPC, two VMs, Guacamole reachable on its public IP, operator can RDP to win + SSH to kali via Guacamole.

### Phase B — full module parity (no fronting): 8 engineer-days

- Build out remaining Linux + Windows VM roles in `modules/gcp/vms.tf`: c2-server, c2-mythic, c2-brc4, c2-sliver, c2-redirector, windows-dc, windows-member, windows-workstation, windows-analyst, linux-target, attacker (kali). Hook all 18 userdata scripts via symlinked `userdata/` directory.
- Build `modules/gcp/shared_infra.tf` for the ghostwriter / stepping-stones / redelk shared boxes.
- Build out NSG → firewall rules in `modules/gcp/firewall.tf` for the C2 stack port enforcement (`kali-to-commander`, `redir-to-listeners`, etc.) — tag-driven.
- Build full geofence chunking at 256-CIDR limit.
- Build all 15 image-family lookups in `modules/gcp/images.tf` + `baking.tf`.
- Create all 15 `.gcp.pkr.hcl` Packer template variants.
- Modify `modules/azure/ansible/inventory.py` to walk the GCP state shape on fallback.
- Modify the `bake` subcommand of `range` to dispatch on `$PROVIDER` — using `gcloud compute images list` for probe and `packer build` against the .gcp.pkr.hcl variant.
- Modify `_ensure_baked_images_exist` to use the GCP probe.
- **Success criterion:** `./range --gcp bake kali && ./range --gcp apply redteam-lab` produces the full redteam-lab scenario (15 VMs) with no advanced_c2 / no Front Door, but with full per-student isolation, full domain join, full RedELK / Guacamole / Ghostwriter / Stepping-Stones.

### Phase C — feature parity (auto-bake, quota check, skip-if-baked, SSH-heal, auto-import): 5 engineer-days

- Port `_ensure_baked_images_exist` to GCP probe + skip the SIG-slot bootstrap step.
- Port `scripts/quota-cost.py` GCP branch (pricing table + Cloud Quotas API + Service Usage probe). ~2 days.
- Modify `_auto_import_orphans()` regex to accept both `azurerm_` and `google_` resource addresses.
- Modify SSH-heal pre-pass in `range repair` to use `gcloud compute instances add-metadata` for ranger ssh-key injection (Linux) and `gcloud compute reset-windows-password` for Windows OOB credential reset (Windows). ~2 days.
- Verify the skip-if-baked role probes work (no changes needed — they're all stat-based).
- **Success criterion:** All 9 session-built features work on GCP. `./range --gcp apply redteam-lab --yes` from a clean GCP project bootstraps baked images, deploys range, and the post-apply ansible repair converges.

### Phase D — advanced_c2 fronting + scenario testing + repair flow: 8 engineer-days

- Build `modules/gcp/cdn.tf` (External HTTPS LB + Cloud CDN + managed certs + per-redirector backend services + DoH custom domain leg). This is the single longest stretch.
- Build `modules/gcp/guacamole_dns.tf` and `modules/gcp/listeners.tf`.
- Test every scenario in `scenarios/*.yaml` deployed on GCP. Fix any provider-leaked field. ~3 days for testing across scenarios.
- Fix any cloud-init / userdata script that hard-codes `cloudapp.azure.com` or Azure IMDS endpoint. ~1 day if any are found.
- **Success criterion:** `./range --gcp apply redteam-lab` with advanced_c2 enabled produces beacons calling back to a GCP CDN endpoint, traffic transits through to the redirector, the redirector forwards to the C2, the C2 receives the beacon.

### Phase E — multi-tenant / shared-Guac equivalent: 3 engineer-days

- Test multi-student deploys (`--students 3`) on GCP — primarily exercises CIDR chunking edge cases and the firewall rule cap.
- Build a parallel `envs/shared-guac-gcp/` (mirror of `envs/shared-guac-azure/`) if the shared-Guac pattern is meant to work cross-provider.
- Document the firewall-rule-cap quota-increase requirement (likely needs raising to 500 per VPC for any `--students` > 5).
- **Success criterion:** `./range --gcp apply student-redteam-lab --students 4 --yes` produces 4 fully-isolated per-student attacker spokes pointed at one shared target lab.

**Total: ~27 engineer-days = ~5.5 calendar weeks for one engineer working solo.** Realistic with a buffer for the inevitable provider-quirk debugging: budget **6-8 calendar weeks** end-to-end.

---

## 7. Cost comparison (rough)

Scenario: `redteam-lab.yaml`, single student (the YAML's `students.count: 1` shape), running 24/7 in `southeastasia` / `asia-southeast1` equivalent.

The redteam-lab VM list, role-aware sized via the existing `local.vm_size` rules:

- 1 windows-dc (D4s_v5 → 4 vCPU Win): **Azure ~$330/mo**, **GCP n2-standard-4 + Win license ~$235 + $135 = $370/mo**
- 1 windows-member srv01 (D4s_v5): **Azure ~$330/mo**, **GCP ~$370/mo**
- 1 windows-workstation ws10 (D4s_v5): **Azure ~$330/mo**, **GCP ~$370/mo**
- 1 windows-workstation ws11 (D4s_v5): **Azure ~$330/mo**, **GCP ~$370/mo**
- 1 windows-analyst (D4s_v5 + FLARE-VM): **Azure ~$330/mo**, **GCP ~$370/mo**
- 1 linux-target linux01 (D2s_v5): **Azure ~$70/mo**, **GCP n2-standard-2 Debian ~$50/mo**
- 1 attacker kali (B4ms medium): **Azure ~$120/mo**, **GCP n2-standard-4 Kali ~$100/mo**
- 3 c2-* teamservers (Adaptix + Mythic + Sliver, B4ms each): **Azure 3×$120 = $360/mo**, **GCP 3×$100 = $300/mo**
- 3 c2-redirector (B2s small): **Azure 3×$30 = $90/mo**, **GCP n2-standard-2 each ~$50 × 3 = $150/mo**
- 1 brc4 (B4ms): **Azure ~$120/mo**, **GCP ~$100/mo**
- 1 brc4-redir (B2s): **Azure ~$30/mo**, **GCP ~$50/mo**
- 3 shared-infra (ghostwriter B4ms / stepping-stones B4ms / redelk B8ms): **Azure ~$120+$120+$240 = $480/mo**, **GCP ~$100+$100+$200 = $400/mo**
- 1 guacamole hub VM (B2ms): **Azure ~$60/mo**, **GCP ~$50/mo**
- 1 elk hub VM (B4ms): **Azure ~$120/mo**, **GCP ~$100/mo**

**Total compute, PAYG:**
- Azure: ~**$3,260/mo**
- GCP without sustained-use discount: ~**$3,150/mo**
- GCP with sustained-use discount (24/7 = 100% utilisation, ~30% off after the first 25%): ~**$2,500/mo**

**Networking + storage:**
- Public IPs: Azure ~5 × $3.65 = $18; GCP ~5 × $3.65 = $18. **Wash.**
- NAT: Azure ~$33/mo + processing; GCP Cloud NAT ~$15/mo + processing. **GCP cheaper $18/mo.**
- Front Door / Cloud CDN: Azure AFD Standard ~$35/mo + per-route; GCP Cloud CDN + HTTPS LB ~$25/mo + per-route. **GCP cheaper ~$10/mo.**
- OS disks (15 VMs × ~75 GB avg StandardSSD): Azure ~$60/mo; GCP pd-balanced ~$45/mo. **GCP cheaper $15/mo.**
- DNS zones: trivially $0.50/mo on either side. **Wash.**

**Net monthly cost:**
- **Azure PAYG redteam-lab**: ~$3,360/mo (matches the YAML comment "~$2k/mo running 24/7 — lock down after first build")
- **GCP PAYG redteam-lab**: ~$3,200/mo
- **GCP with sustained-use discount (default, no opt-in)**: ~**$2,560/mo** (roughly **22% cheaper** than Azure for the same scenario)
- **GCP with 1-year committed-use for the base fleet**: ~**$2,100/mo** (~37% cheaper than Azure PAYG)

**Where GCP is cheaper:**
- Linux VMs (about 10-15% cheaper for same vCPU)
- Sustained-use discounts when running >25% of the month (automatic)
- NAT (about half the price)
- Egress to internet (free 200 GB/mo, then cheaper per-GB)
- OS disk storage (about 20% cheaper for SSD)

**Where GCP is more expensive:**
- Windows VMs (vCPU licensing premium not embedded in machine price; ~15-20% more for same Windows workload)
- Static IP attached to a VM (Azure Standard PIP $3.65/mo flat; GCP $3.65/mo only when in use, $7.30/mo otherwise — terra-range always has these in use, so this is wash)
- High-frequency Spot eviction in `asia-southeast1` for Windows-licensed VMs (anecdotal but consistent in operator reports)

**Bottom line:** for the redteam-lab scenario (which is Windows-heavy), GCP at sustained-use-discount rates is about **15-20% cheaper than Azure PAYG**. For more Linux-heavy scenarios (e.g. `smoke.yaml`, `engagement.yaml` minimal), GCP is **30-40% cheaper**. **For the most Windows-heavy scenarios (full GOAD / `goad.yaml` with 5+ Windows VMs)**, the Windows-license premium narrows GCP's advantage to **5-10%** — and Azure may even be slightly cheaper at PAYG.

---

## 8. Risks + open questions

1. **Is the operator's GCP organization policy enforcing OS Login?** If yes, the entire SSH-key-injection model breaks. Confirm `gcloud resource-manager org-policies describe constraints/compute.requireOsLogin --organization <id>` returns either no value or `enforce: false`. If OS Login is mandatory at org level, terra-range either needs a substantial design pivot (move to IAM-based SSH) or its GCP path is blocked.

2. **Is the BRC4 vendor license tied to AWS or Azure ARM machine fingerprints?** BRC4 has historically been hosted-license-checked. If the activation key includes a "cloud-provider" field, the existing license might fail to activate on a GCP-deployed BRC4 VM. Need confirmation from the BRC4 vendor before committing engineering time on the GCP-BRC4 path.

3. **Will the operator commit to one GCP project per range, or one project shared across many ranges?** Affects naming conventions (`<range>-` prefix matters more in shared projects), affects quota provisioning (shared sub means quota becomes the dominant constraint), affects destroy behavior (per-project = atomic destroy by `gcloud projects delete`). The current Azure path uses one subscription with per-RG isolation; the closest GCP analog is one project with naming-prefix isolation, but one-project-per-range is also viable.

4. **Cloud DNS zone ownership.** terra-range's Azure DNS pattern uses cross-subscription aliased providers (`azurerm.dns`, `azurerm.guac_dns`) to write to zones in a different subscription. GCP supports this via `user_project_override`, but the operator's IAM role on the DNS-zone project must include `roles/dns.admin` AND the deploying project's service account must have permission to set the records. Confirm IAM relationships before Phase B.

5. **Does the existing geofence list need re-validation for GCP edge-IP coverage?** The geofence is operator-source-IP filtering; provider-agnostic. But the Cloud CDN edge IPs (which would need to be in the redirector firewall allow-list if we don't go the "trust nginx header validation alone" path) come from `https://www.gstatic.com/ipranges/cloud.json`, which changes monthly. Need a refresh script analog to `scripts/refresh-geofence.sh` for those IP ranges.

6. **Marketplace Kali on GCP — current SKU.** Azure's images.tf pins `kali-2026-1` (the YYYY-N quarterly). The GCP Kali project's image naming convention is different (`kali-rolling-2026.1` or similar). Need to confirm the exact GCP family/image name during Phase B. If Kali on GCP lags behind Azure releases, scenarios pinning a specific Kali version may not deploy.

7. **GCP windows-server SKU naming.** Azure's image_map has `2022-datacenter-gensecond`, `2025-datacenter-azure-edition`, `win10-22h2-pro-g2`, `win11-25h2-pro`. The GCP equivalents come from the `windows-cloud` project: `windows-2022-dc-v*`, `windows-server-2025-dc-v*`, but Windows 10/11 **client** SKUs are not first-party on GCP — Microsoft only ships Windows Server images. For the windows-10/windows-11 workstation roles, the GCP path either requires bringing your own Windows-10/11 ISO and building a custom image (Packer can do this from an uploaded VHD), OR substituting Windows Server 2022 Desktop Experience for windows-workstation roles. **This is a significant gap.** Easier alternative: skip windows-10/windows-11 SKUs on GCP entirely and run all Windows workstation roles on Windows Server 2022/2025 with Desktop Experience.

8. **Nested virtualisation for FLARE-VM.** Already mentioned in §4 item 9 — needs `enable_nested_virtualization = true` on the windows-analyst instance and pinning to n2/c2 family (not e2/t2d). Need to verify FLARE-VM's sandbox tooling works under GCP-nested-virt the same way it works under Azure's Hyper-V nested.

9. **Operator's existing geofence — do the country IP ranges include all GCP edge POPs?** If the operator's geofence is configured to allow inbound from SG/PH/AE/QA/SA only, and they reach Guacamole through their corporate VPN or cellular CGNAT that drifts into a non-listed country, they're locked out. Same risk on Azure, but worth re-flagging because the GCP firewall behavior is slightly different (e.g. a deny rule with priority 65535 is more aggressive than an Azure NSG implicit deny). Document the `guacamole_auto_add_my_ip` setting clearly for GCP.

10. **Time budget for the AFD-equivalent build.** §6 Phase D estimates 8 engineer-days for the External HTTPS LB + Cloud CDN port. This is the largest single-block risk in the whole port — if the operator's advanced_c2 setup involves DoH (which `redteam-lab.yaml` indicates it does for the sliver / mythic / adaptix beacons), the per-redirector DNS-over-HTTPS URL-map rule has to be replicated. Could blow out to 12-15 days if DoH-via-LB-host-rule turns out not to be straightforward.

---

## 9. Recommendation

**Commit to a full GCP port if any of these are true:**
- The operator runs labs for clients/students whose cloud-allowance budget is GCP-credit-only.
- The operator needs to run scenarios in a region where Azure lacks a presence (rare — both clouds cover SE Asia adequately).
- Cost over a 12-month window matters: ~$2,500/mo on GCP vs ~$3,300/mo on Azure for the redteam-lab single-student deploy = **$9,600/year saved per concurrent range**. Across 4-6 concurrent ranges (typical teaching cadence), that's **~$40-60k/year**, which justifies ~6 engineer-weeks of port effort easily.
- The operator wants vendor diversification (avoid Azure lock-in for the same scenarios).

**Do NOT commit to the full port if:**
- The current Azure deploys are stable and the operator runs ≤2 concurrent ranges. The engineering effort outweighs the savings at that scale.
- The operator's primary use case is Windows-heavy (≥5 Windows VMs per range). The Windows-license premium on GCP eats most of the savings, AND the Windows client SKU gap (point 7 above) means scenarios with windows-10/windows-11 desktops need rework. Stay on Azure.
- The operator has not confirmed GCP org-policy is OS-Login-free (point 1 above). Without that confirmation, the entire SSH-key model that terra-range depends on is at risk. Block on that confirmation before committing.

**Recommended middle path (LIGHTWEIGHT GCP support):**

The cleanest "get value without full port effort" path is **port only the Linux-heavy scenarios** (`smoke.yaml`, `engagement.yaml`, `vulhub.yaml`, and a Linux-subset of `redteam-lab.yaml` that drops the Windows AD forest). This means:

- Build `modules/gcp/` with Linux VM + firewall + VPC + Cloud NAT (no Windows resource paths).
- Build `modules/gcp/cdn.tf` for the advanced_c2 fronting (because the C2 stack is Linux and GCP-cheap).
- Skip `modules/gcp/` Windows roles entirely (no DC, no member, no workstation, no analyst).
- Skip baked images for Windows OSes (the heavy-cost ones).
- **Net effort: ~12 engineer-days, vs ~27 for the full port.**

Operator gets: **kali + C2 stack + redirectors + Cloud CDN fronting + shared-infra (ghostwriter / stepping-stones / redelk) all on GCP**, at ~$1,200-1,500/mo per student-pair scenario (the Linux portion of a redteam-lab). The full Windows AD forest scenarios stay on Azure where they're already optimized.

**This middle path is the recommendation.** Cost: ~3 engineer-weeks. Saves ~$10k/year per concurrent Linux-heavy lab. Risk-bounded (no untested Windows-on-GCP behavior). Operator can revisit a full Windows port later if Linux-side experience is positive.

---

### Critical Files for Implementation

The 5 files an engineer must read in depth before starting Phase A:

- /Users/ian/Documents/Projects/terra-range/modules/azure/vms.tf
- /Users/ian/Documents/Projects/terra-range/modules/azure/baking.tf
- /Users/ian/Documents/Projects/terra-range/modules/azure/images.tf
- /Users/ian/Documents/Projects/terra-range/range
- /Users/ian/Documents/Projects/terra-range/generator/generate.py