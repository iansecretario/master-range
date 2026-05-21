# cyber-range

Multi-tenant cyber-training range generator. One YAML defines a per-student
machine template; the generator clones it across N students into isolated
VNets, all peered to a single hub running Apache Guacamole and ELK. Targets,
attacker workstations, AdaptixC2 teamservers, and HTTPS redirectors are
provisioned per student.

## Layout

```
generator/
  range.example.yaml        Range definition (commented schema reference)
  generate.py               YAML -> terraform.tfvars.json
scenarios/                  Ready-to-run scenario YAMLs
  smoke.yaml                  Single student, fastest pipeline test
  class.yaml                  20-student red-team class
  engagement.yaml             5-operator engagement with AFD-fronted C2
  ehvapt.yaml                 eHVAPT exam shape (2 win + 3 linux per candidate)
  themed.yaml                 Persona showcase (Stark / Sentry / Warrrix)
  vulhub.yaml                 Ludus-equivalent: Vulhub CVE labs per student
  adcs.yaml                   Ludus-equivalent: ADCS with ESC1/ESC2 templates
  splunk-ar.yaml              Ludus-equivalent: Splunk Attack Range
personas/                   Themed lab scripts for linux-target + windows-member/workstation
  starky.sh                   Stark Industries — corporate compromise chain (15 flags)
  sentry.sh                   SOC-themed skeleton
  warrrix.sh                  Hardened-appearing Linux skeleton
  vulhub.sh                   Vulhub Docker CVE catalogue
  adcs.ps1                    AD CS Enterprise CA + ESC1/ESC2 templates
  splunk-server.sh            Splunk Enterprise indexer + HEC + receivers
  splunk-uf.ps1               Splunk Universal Forwarder + Sysmon (Windows)
modules/
  azure/                    Full Azure implementation (priority)
  aws/                      Stub — see modules/aws/README.md
envs/
  azure/main.tf             `terraform init && apply` here
  aws/                      Generated tfvars only; module pending
range                       One-command CLI wrapper (./range list, apply, lock, ...)
LUDUS-COVERAGE.md           Mapping of Ludus environment guides to our scenarios
REVIEW.md                   In-depth audit + outstanding issues
```

## How it works

1. You write a single `range.yaml` containing
   - a `students:` block (`count`, `tenancy`, `name_format`)
   - a `machines:` block — the **per-student** machine template
2. `generate.py` validates and expands: each student gets one of every
   machine in the template, prefixed with `<student_id>-` (e.g. `s01-dc01`,
   `s07-c2`). Static IPs are rebased into the student's `/22`
   (`10.<student_index>.0.0/22`).
3. Terraform deploys
   - one **hub** RG + VNet (`10.0.0.0/22`) running Guacamole + ELK
   - one **spoke** RG + VNet per student (`10.<n>.0.0/22`), peered to the hub,
     containing target subnet (`.0/24`) and attacker subnet (`.1/24`)
   - all VMs, NICs, NSGs, NAT, peerings
4. On first boot, the Guacamole VM consumes a manifest of every machine +
   credentials, and via the Guacamole REST API:
   - creates one connection group per student
   - creates one RDP/SSH connection per machine, pre-filled with creds
   - creates one Guacamole user per student with READ-only access to that
     student's group
5. Each student visits `https://<guac-fqdn>/`, logs in as
   `student-s01` / `Student!01`, and sees only their own machines.

## Roles

### Per-student (defined under `machines:`)
| Role               | Subnet           | OS default          | Notes |
| ------------------ | ---------------- | ------------------- | ----- |
| `windows-dc`       | targets          | Windows Server 2022 | Auto-promoted to forest root. Local admin forced to match `domain.admin_user`. One per student. |
| `windows-member`   | targets          | Windows Server      | Optional `domain_join: true`. |
| `windows-workstation` | targets       | Windows 10/11       | Optional `domain_join: true`. Marketplace SKU; needs MTHR or VSS. |
| `linux-target`     | targets          | Ubuntu/Debian       | Optional Filebeat shipping to ELK. |
| `attacker`         | attacker         | Kali                | XFCE + TigerVNC (Xtigervnc on display `:1`, port 5901). Guacamole connects via VNC, not RDP — xrdp on cloud VMs is a 10-fix gauntlet (vsock/GLAMOR/DRMDevice/session-policy); TigerVNC is one apt + one systemd unit. SSH key from `services.adaptix.ssh_pubkey`. |
| `c2-server`        | attacker (`.5`)  | Debian 12           | AdaptixC2 teamserver, systemd-managed. |
| `c2-redirector`    | attacker (`.6`)  | Debian 12           | nginx HTTPS proxy fronting the c2-server. AFD-aware (see Advanced C2). |

You can have **2-5 boxes per attacker side per student** (e.g. `kali01`,
`kali02`, `c2`, `redir`, plus a payload host) — just add them to the
`machines:` template and they're cloned for every student.

### Shared infrastructure (defined under `shared_infrastructure:`)
Deployed once into the hub (not per student). Each gets a public IP
gated by `guacamole_ingress_cidrs` and an SSH connection auto-registered
in Guacamole under the `shared-infra` group.

| Role              | Tool                                                        | Default web URL |
| ----------------- | ----------------------------------------------------------- | ----------------|
| `ghostwriter`     | [GhostManager/Ghostwriter](https://github.com/GhostManager/Ghostwriter) — engagement + reporting | `https://<pip>/` |
| `stepping-stones` | [nccgroup/SteppingStones](https://github.com/nccgroup/SteppingStones) — operator activity tracker | `http://<pip>:8000/` |
| `redelk`          | [outflanknl/RedELK](https://github.com/outflanknl/RedELK) — red-team SIEM | `http://<pip>:5601/` once initial-setup is run |

The bootstrap scripts clone each upstream repo and prep dependencies.
Ghostwriter and SteppingStones auto-start their `docker-compose` stacks.
RedELK requires a manual `initial-setup.sh` run (it generates certs and
needs operator-supplied config); SSH in via Guacamole and finish from
there.

#### Ephemeral Kali workspace pool (`services.workspaces`)

Optional dedicated VM running a docker pool of ephemeral Kali containers,
exposed through Guacamole as `kali-2-1..N`. Each container is a fresh
`kalilinux/kali-rolling` + XFCE + TigerVNC, started with `--rm` so an
idle-slot recycle (cron, every 30 min by default) gives back a clean
filesystem — "zero state accumulation between sessions". Enable via:

```yaml
services:
  workspaces:
    enabled: true
    pool_size: 4                  # number of slot containers
    vm_size: Standard_D4s_v4      # bump to D8s_v4 if pool_size > 4
    auto_restart: true            # idle slots get torn down + respawned
    restart_interval_min: 30
```

The VM lives in `hub_infra` (10.0.1.50) — **NOT** co-located with
Guacamole, because Kali containers run aggressive pentest tools and
container-escape blast-radius must not include the Guac control plane.
guacd at the Guac VM reaches `10.0.1.50:5901..5909` via a dedicated
`from-guacamole-vnc` NSG rule.

For ranges already deployed without `workspaces`: enable it in the
scenario YAML, `terraform apply` to create the VM, then run
**`./range workspaces-reconcile`** to push the new `kali-2-<i>`
connections into the live Guacamole DB (the Guac VM has
`lifecycle { ignore_changes = [custom_data] }`, so a plain apply alone
doesn't propagate new connection entries).

## Personas (themed `linux-target` + `windows-member`/`workstation` boxes)

Any `linux-target`, `windows-member`, or `windows-workstation` machine
can opt into a **persona** — a self-contained script that turns the box
into a themed CTF lab or pre-configured service host. Personas live in
`personas/<name>.sh` (Linux) or `personas/<name>.ps1` (Windows) and are
referenced by name from the YAML:

```yaml
machines:
  - { name: starky,  role: linux-target,    os: debian-12,            persona: starky  }
  - { name: ca01,    role: windows-member,  os: windows-server-2022,  domain_join: true, persona: adcs }
  - { name: vulhub,  role: linux-target,    os: ubuntu-22,            persona: vulhub  }
```

The generator picks `.sh` vs `.ps1` based on the machine's role. Mismatch
fails fast.

What happens at deploy:

1. Generator validates `personas/<name>.{sh,ps1}` exists and embeds it
   (base64) in tfvars.
2. The module renders a different bootstrap for that VM
   (`linux-persona.sh` or `windows-persona.ps1`) that does standard
   role setup (user/SSH for Linux, firewall/RDP/optional domain-join
   for Windows), then runs the persona script as root/SYSTEM.
3. After the persona finishes, an **auto-clean** step wipes build traces:
   - persona script file shredded
   - cloud-init logs (Linux) or CSE plugin status files (Windows) truncated
   - cached user-data / EncodedCommand removed

Cleanup is deliberately narrow — anything the persona itself wrote
(fake `.bash_history` files, planted flags, sensitive `/var/backups/`
content, AD users, certificate templates, registry keys) is preserved.
Only build artefacts are scrubbed.

Bundled personas:

| Name             | Type    | Theme |
| ---------------- | ------- | ----- |
| `starky`         | Linux   | Stark Industries — full corporate compromise chain (15 flags, 2225 pts) |
| `sentry`         | Linux   | SOC operations centre, intentionally misconfigured (skeleton) |
| `warrrix`        | Linux   | Looks-hardened box with deep capability/cron privesc paths (skeleton) |
| `vulhub`         | Linux   | Vulhub CVE catalogue runner — Log4Shell, Spring4Shell, Struts2, etc. |
| `splunk-server`  | Linux   | Splunk Enterprise indexer + HEC + receiver port + preset indexes |
| `adcs`           | Windows | AD CS Enterprise CA + ESC1/ESC2 vulnerable certificate templates |
| `splunk-uf`      | Windows | Splunk Universal Forwarder + Sysmon shipping to a paired indexer |

Add a new persona by dropping a script in `personas/` and referencing
it by name. See `personas/README.md` and `LUDUS-COVERAGE.md` for
authoring guidance.

## Advanced C2 (Azure Front Door)

Set `advanced_c2.enabled: true` in your YAML to insert Azure Front Door
in front of every student's redirector:

```
Internet → AFD (s01.enterprisestudio.com) → redirector (public IP) → c2-server
            ↓ (s02.enterprisestudio.com)
                   → redirector → c2-server
            ...
```

Configuration:
```yaml
advanced_c2:
  enabled: true
  domain: enterprisestudio.com
  dns_zone_resource_group: dns-rg          # the RG holding your Azure DNS zone
  cover_url: "https://www.microsoft.com"   # 302 target for non-C2 traffic
  fdid_header_required: true               # nginx rejects requests without matching X-Azure-FDID
  student_subdomain_format: "{sid}"        # s01.<domain>, s02.<domain>, ...
```

What gets provisioned:
- 1× `azurerm_cdn_frontdoor_profile` (Standard SKU)
- 1× endpoint
- N× origin group + origin (one per redirector, pointing at its public IP)
- N× custom domain (`s01.enterprisestudio.com` …) with managed TLS
- N× route binding domain → origin group, `link_to_default_domain = false`
  so the AFD default URL doesn't accept anything
- DNS validation TXT and CNAMEs auto-created in the configured Azure DNS zone

Redirector hardening when AFD is on:
- Public IP attached, NSG ingress restricted to `AzureFrontDoor.Backend`
  service tag on :443, scoped to redirector's pinned `10.<n>.1.6` IP so
  Kali / c2-server stay private
- nginx validates `X-Azure-FDID` against the AFD profile's `resource_guid`
  (rejected requests get 302 to `cover_url`)
- Cover identity: `Server: Microsoft-IIS/10.0` header, `/` returns 200
  with bare "OK", anything else returns 302 to `cover_url`
- Only `/endpoint` (Adaptix's default beacon path) is proxied to the
  teamserver — extend in `userdata/c2-redirector.sh` to match your
  malleable profile

DNS prerequisites:
- Your DNS zone for the chosen domain must already exist in Azure DNS
  (`az network dns zone create -g <rg> -n enterprisestudio.com`) and
  the registrar's nameservers must point there
- Or set `dns_zone_resource_group: ""` to skip Terraform-managed DNS
  and create the TXT/CNAME records yourself; AFD will not validate
  the custom domains until both records are in place

Toggling `advanced_c2.enabled` flips the redirector userdata, which
forces VM replacement of every redirector (Azure `custom_data` is a
ForceNew field). Plan the change with `terraform plan` first.

### AFD validation timing — first-deploy gotcha

Azure Front Door's managed-certificate flow is asynchronous. After
`terraform apply` creates the custom-domain + TXT validation + CNAME
records, AFD itself takes **5–15 minutes** to:

1. Poll DNS for `_dnsauth.<host>` TXT and confirm the validation token
2. Issue the managed Let's Encrypt cert
3. Mark the domain "Approved" and start serving HTTPS on it

During that window, beacons hitting `https://<sub>.<domain>/` get
errors (no cert) or 404 (route not yet active). To handle this:

- terra-range's default is to **block `terraform apply`** for
  `advanced_c2_validation_wait_minutes` (default 20) so the wait is
  baked into the apply rather than something the operator hits as
  a surprise.
- Set `-var advanced_c2_validation_wait_minutes=0` to skip the block
  and poll yourself with **`./range afd-status`** — that calls
  `az afd custom-domain list` and prints each domain's
  `domainValidationState` (Pending → Submitting → Approved).

Common reasons validation never reaches Approved:

- DNS zone `data` lookup pointed at the wrong RG (TXT record never
  written → AFD polls forever)
- Registrar nameservers don't yet point at Azure DNS NS records
- TXT record exists but with a stale token (custom domain was
  recreated but TXT wasn't refreshed — `terraform taint` the TXT
  resource and re-apply)


## Prerequisites

- Azure subscription with quota for `count(students) * count(machines)` cores
- `az login` then `az account set --subscription <id>`
- Marketplace terms accepted **once per subscription** for any image you use:

  ```
  az vm image terms accept --urn kali-linux:kali:kali-2024-4:latest
  az vm image terms accept --urn microsoftwindowsdesktop:windows-11:win11-23h2-pro:latest
  az vm image terms accept --urn microsoftwindowsdesktop:windows-10:win10-22h2-pro-g2:latest
  ```
- Windows 10/11 client SKUs require Multi-tenant Hosting Rights or a
  qualifying Visual Studio subscription. See Azure docs.
- Terraform >= 1.6
- Python 3.9+ with PyYAML (`pip install -r generator/requirements.txt`)

## Quickstart

```bash
# 1. Edit the range definition
$EDITOR generator/range.example.yaml

# 2. Generate tfvars
python3 generator/generate.py generator/range.example.yaml --provider azure

# 3. First apply: lockdown=false so cloud-init/CSE can install packages
cd envs/azure
terraform init
terraform apply

# 4. Wait ~15-25 min for all VMs to finish first-boot installs
#    (DC takes longest because of two-phase promotion+reboot)

# 5. Re-apply with lockdown=true to remove NAT and seal the targets
terraform apply -var=lockdown=true
```

Outputs:

```
guacamole_url            = "https://ctf-redteam-01-abc123.eastus.cloudapp.azure.com"
guacamole_admin_user     = "guacadmin"
guacamole_admin_password = <sensitive>
elk_kibana_url           = "http://20.x.y.z:5601"
student_logins           = <sensitive>
machine_ips              = { s01-dc01 = "10.1.0.10", s01-srv01 = "10.1.0.5", ... }
summary                  = { range = "ctf-redteam-01", students = 20, machines_total = 200, lockdown = false }
```

`terraform output student_logins` reveals each student's credentials.

## Lockdown workflow

Targets and attackers must reach the internet during first boot so
cloud-init/CSE can install Sysmon, Winlogbeat, AdaptixC2 source, etc.

- `lockdown: false` — NAT gateway attached to target+attacker subnets.
  Outbound NSG rule `out-internet-build` is `Allow`.
- `lockdown: true` — NAT gateway resources are not provisioned, and the
  outbound NSG rule flips to `Deny`. Targets and attacker boxes have
  **zero** internet egress. They can still reach each other and the hub.

The hub (Guacamole, ELK) keeps its public IPs on either toggle so
operators can keep accessing the range.

## Detection / blue-team angle

- Sysmon (SwiftOnSecurity config) is auto-deployed to all Windows hosts
- Winlogbeat ships Application/System/Security/Sysmon channels (plus
  Directory Service + DNS Server on the DC) to the hub ELK
- Filebeat (when `services.elk.deploy_agents: true`) ships syslog and
  auth.log from Linux targets
- The **C2 redirector** listens on `:443` and proxies only `/endpoint` to
  the teamserver, returning 200 on `/` and 404 elsewhere. The cover page
  is configurable in `userdata/c2-redirector.sh`.
- Each student's range is a separate VNet; lateral movement detections
  fire only inside one student's blast radius.

## Adding/removing students

```yaml
students:
  count: 25     # was 20
```

Re-run the generator and `terraform apply`. Terraform adds the new RGs,
VNets, peerings, and VMs without touching existing students. Removing a
student is the same operation in reverse.

## Cost notes (rough, eastus, B-series)

- 20 students × 10 machines (B2s small / B4ms medium) ≈ 100 cores running
- Standard NAT gateway: ~$32/mo per student (only when `lockdown=false`)
- ELK + Guacamole hub: ~$120/mo
- Public IPs (hub Guacamole + ELK + per-student NAT): ~$4/mo each

To minimise spend, deploy with `lockdown=false` for ~30 minutes during
build, then immediately `lockdown=true` to deprovision NAT.

## AWS

Pending. See `modules/aws/README.md`. The generator already emits
`envs/aws/terraform.tfvars.json` with `--provider aws` or `--provider both`.

## Project hygiene

- The Guacamole admin password and per-student passwords in
  `range.example.yaml` are placeholders. Rotate before a real run.
- Plaintext passwords currently flow through tfvars — wire to Key Vault
  for a production setup.
- The Adaptix `ssh_pubkey` in the example is a dummy. Replace it with the
  operator's real key before deploying.

## Lifecycle, state, and destroy recovery

### Geofencing Guacamole + shared infra by country

Guacamole's admin password is a 24-char random string from
`random_password` — practically un-brute-forceable — but exposing the
web UI to the entire internet (`guacamole_ingress_cidrs:
["0.0.0.0/0"]`) still attracts script-kiddie noise and burns your
public IP for OSINT. Two layered controls:

```yaml
# scenarios/redteam-lab.yaml
guacamole_allow_countries: [SG, PH, AE, QA, SA]   # geofence
guacamole_auto_add_my_ip: true                    # apply-time IP whitelist
```

**Layer 1 — country geofence.** `./scripts/refresh-geofence.sh`
downloads aggregated CIDR zones for each country code from ipdeny.com
into `geofence/<CC>.txt` (gitignored; data ages weekly). The generator
merges the listed countries into `guacamole_ingress_cidrs` at apply
time. The hub NSGs use `chunklist(..., 3500)` so the list can exceed
Azure's 4000-entries-per-NSG-rule limit — up to ~17500 CIDRs supported.
`./range apply` auto-runs the refresh script for any missing country
file, so first-deploy needs no prep.

**Layer 2 — auto-detect operator IP.** `guacamole_auto_add_my_ip:
true` makes the generator hit `api.ipify.org` (with fallbacks to
`icanhazip.com` and `checkip.amazonaws.com`) at generation time and
prepend the detected `<ip>/32` to the ingress list. This covers VPN
exits, mobile carrier CIDRs, or partner offices whose IPs drift
outside the country snapshot. Best-effort: if all three sources fail
(offline, corp firewall blocks the lookup), the generator warns and
continues without the auto-add — you can still reach via the country
geofence.

**Override path.** Setting `guacamole_ingress_cidrs:` explicitly in
the YAML wins over both layers. Use it when you want exact operator
IPs and nothing else.

Default for `redteam-lab` is the 5-country geofence above
(SG/PH/AE/QA/SA → ~4300 CIDRs total) plus the auto-IP-add. AU was
intentionally dropped — its aggregated zone alone is ~5600 CIDRs which
overflows the per-NSG-rule budget. Add it back explicitly if needed:

```bash
./scripts/refresh-geofence.sh AU           # also fetch AU
# then in the scenario YAML:
guacamole_allow_countries: [SG, PH, AE, QA, SA, AU]
```

Update commands:

```bash
./scripts/refresh-geofence.sh              # the 5 default countries
./scripts/refresh-geofence.sh JP KR US     # arbitrary country list
```

### Marketplace terms — accept all SKUs at once

Kali and Windows publishers rotate SKUs every few months. The
`az vm image terms accept --urn …:latest` form fails when a specific
SKU is no longer published (`Can't resolve the version`). Cleaner
approach:

```bash
./range accept-marketplace                  # default region southeastasia
./range accept-marketplace eastus           # different region
```

This enumerates every currently-published SKU under
`kali-linux:kali`, `microsoftwindowsdesktop:windows-10`, and
`microsoftwindowsdesktop:windows-11` in your subscription's region,
then `terms accept`s each one with the `--plan` form (no `latest`
resolution needed). Output is `[+]` accepted / `[.]` no-terms /
`[!]` failed per SKU, plus a summary listing the **most-recent SKU
per offer** so you can sanity-check
[modules/azure/images.tf](modules/azure/images.tf) is pointing at one
that exists.

After running this once, every scenario that uses Kali / Win10 / Win11
deploys without Marketplace prompts. Re-run if you change subscription
or region; otherwise it's a one-time setup.

The preflight check itself reads the SKU directly from `images.tf` so
it stays in sync — no hardcoded URN list to drift.

### Pre-flight before a real apply

```
./range preflight <scenario>
```

Runs four checks before you spend a cent in Azure:

1. **`az account show`** — confirms you're logged into a subscription.
2. **Marketplace terms** — for every gated image the scenario uses
   (Kali, Win10, Win11), checks `az vm image terms show` and tells
   you the exact `az vm image terms accept --urn …` command if any
   aren't accepted yet.
3. **vCPU quota** — runs `az vm list-usage --location <region>`,
   buckets the scenario's VMs by quota family (Standard BS Family
   vCPUs / Standard DSv5 Family vCPUs), and compares needed-vs-
   available. If a family is short, you get the shortfall in vCPUs
   and a pointer to the Azure portal quota-increase form.
4. **Cost estimate** — rough monthly USD against East US PAYG
   pricing: VMs (per SKU), public IPs, NAT gateways, AFD profile,
   OS disks. Results are public-list pricing — ignores reservations,
   savings plans, data egress.

`./range apply` runs the same four automatically (warning, not
blocking — operator may continue past warnings). The explicit
`preflight` command lets you fix things up-front.

```
./range cost <scenario>
```

Cost-only report (skips quota + Marketplace checks, doesn't touch
Azure). Useful for "what would scenario X cost me" before deciding
whether to run preflight + apply.

### Spot pricing (`--spot`)

Default is Regular priority. Pass `--spot` after the scenario name to
flip every VM in the range — per-student, shared infra, and hub
services — to Azure Spot pricing. Typical discount is **60–90% off
PAYG** depending on region + capacity. The cost report applies a
conservative 80% discount so the figure is realistic-low rather than
wildly optimistic.

```bash
./range apply redteam-lab --spot     # all VMs come up as Spot
./range cost  redteam-lab --spot     # see what Spot would cost first
```

### Critical roles stay Regular even under `--spot`

Under `--spot`, two roles are **pinned to Regular priority**
regardless of what you pass:

- `windows-dc` — Spot eviction during DC promotion produces a
  half-built forest that AD cannot recover from. Recovery would be a
  full rebuild.
- `c2-redirector` — eviction during AFD's cert-validation poll leaves
  the custom domain in `Rejected` state; recovery requires
  `terraform taint` on the custom_domain + reapply.

Implementation lives in `local.spot_pinned_roles` in
[modules/azure/images.tf](modules/azure/images.tf). The cost report
shows these explicitly when `--spot` is set:

```
VMs by SKU (15 total — 11 Spot, 4 pinned to Regular [DC + redirectors])
  Standard_B2s          count=3   cores=6    ~$96/mo (Spot×0+Reg×3)
  ...
```

For redteam-lab specifically: 1 DC + 3 redirectors stay PAYG
(~$230/mo), the other 11 boxes ride Spot. Net is still ~60-70% off
full PAYG.

### Eviction tradeoffs for non-pinned roles

Tradeoff: Azure can evict any non-pinned Spot VM **at any time** when
capacity gets tight. terra-range sets `eviction_policy = "Deallocate"`
so the OS disk + state survive eviction — operators bring the box
back with:

```bash
az vm start -g <rg> -n <vm-name>
# or batch-restart everything Spot has reclaimed:
az vm start --ids $(az vm list --query "[?powerState=='VM deallocated'].id" -o tsv)
```

When NOT to use `--spot`:

- **Live engagements** — eviction during an op = lost callbacks
- **Multi-day classes with active students** — they'll watch boxes drop
- **Logging-heavy boxes that can't tolerate gaps** — RedELK / ELK can lose unflushed buffer

When `--spot` is fine:

- **Lab / testing scenarios** like `redteam-lab`
- **Solo dev work** — restart what gets evicted, save the money
- **CI smoke tests** — short-lived, eviction doesn't matter

You can also bake it into a YAML if a scenario should always be Spot,
by adding `vm_priority: Spot` at the top of the scenario file (the
`--spot` CLI flag overrides if both are present).

### Recovering an evicted Spot VM

When Azure reclaims capacity, any non-pinned Spot VM gets deallocated
(disk + config preserved, just powered off). You'll see it as
"VM deallocated" in the portal. Three recovery paths in order of
escalation:

**1. Plain restart — works for steady-state services**

```bash
az vm start -g <rg> -n <vm>
# or batch all evicted boxes in a range:
az vm start --ids $(az vm list \
  --query "[?powerState=='VM deallocated' && tags.Range=='redteam-lab'].id" -o tsv)
```

OS state, installed packages, AD domain join, BRC4 license activation,
Adaptix listener config all survive. The VM comes up running whatever
services were enabled via systemd before eviction.

**2. Re-run cloud-init — when bootstrap was incomplete**

Cloud-init runs ONCE per instance by default. If eviction caught the
VM mid-bootstrap (apt install, git clone, image pull), you'll see a
running VM with a half-installed service. Diagnose with:

```bash
ssh ranger@<vm-ip>
sudo tail -50 /var/log/cloud-init-output.log
```

The last lines show where it stopped. To force cloud-init to run from
the top again:

```bash
sudo cloud-init clean --logs
sudo cloud-init init --local
sudo cloud-init init
sudo cloud-init modules --mode=config
sudo cloud-init modules --mode=final
# or simpler, but reboots the box:
sudo cloud-init clean --reboot
```

This is destructive — any state cloud-init wrote (users, SSH keys,
cloud-init-managed files) will be reset.

**3. Taint and replace — last resort**

For unrecoverable boxes (AD member with broken realm join, Mythic
with corrupt Docker state, etc.):

```bash
cd envs/azure
terraform taint module.range.azurerm_linux_virtual_machine.machine[\"<name>\"]
terraform apply
```

Replaces just that VM. Other boxes are untouched. For a Windows DC,
this is destructive at the forest level — every member would need to
re-join. Don't taint the DC.

### Roles to manually verify after Spot eviction

- **C2 teamservers** — `systemctl status adaptix mythic brc4 filebeat`;
  any of them red, see /var/log/{adaptix,mythic-build,brc4}.log
- **AD members** — `Test-ComputerSecureChannel` from PowerShell on the
  member; if it returns False, run `Reset-ComputerMachinePassword`
- **linux01 (realm-joined)** — `realm list` on the box; if empty,
  re-run the persona script from `/tmp/persona.sh` (still on disk
  unless cloud-init cleanup wiped it)

### Per-apply overrides

Any subcommand that runs the generator (`gen`, `plan`, `apply`,
`preflight`, `cost`, `diff`) accepts these flags after the scenario
name — they override the YAML on the fly without editing it:

| Flag                   | Overrides                                        | Example                                        |
| ---------------------- | ------------------------------------------------ | ---------------------------------------------- |
| `--domain <fqdn>`      | `domain.fqdn`. NetBIOS auto-derived from the first dotted label, uppercased, capped at 15 chars. | `--domain ian.local` → fqdn `ian.local`, netbios `IAN` |
| `--admin-user <name>`  | `domain.admin_user`                              | `--admin-user darthadmin`                      |
| `--students N`         | `students.count`                                 | `--students 5`                                 |

Examples:

```bash
# Same redteam-lab YAML, but use ian.local instead of corp.local
./range apply redteam-lab --domain ian.local

# Engagement scenario re-targeted at a customer-themed domain + admin
./range apply engagement --domain redteamlabs.dev --admin-user opadmin

# What would a 10-operator engagement cost?
./range cost engagement --students 10
```

Overrides validate the same way YAML fields do — invalid input
(spaces in domain, missing dot, etc.) fails fast before any tfvars
get written.

> Pricing data lives in `scripts/quota-cost.py` (`SKU_PRICE_USD_MO`
> dict). When Azure raises prices, edit the table and the rest of
> the report follows.

### State file lifecycle

terra-range uses Terraform's local backend by default — state lives at
`envs/azure/terraform.tfstate`. Implications:

- **Sensitive values are in plaintext** there: random domain admin
  passwords, Adaptix/Mythic/BRC4 teamserver passwords, BRC4 license
  credentials, AFD profile GUIDs. Treat the file as a secret.
- **No backups by default.** A corrupt or deleted state file means you
  can't `terraform destroy` what's in Azure (you'd have to nuke by tag
  — see below).
- **Single operator.** Two people running `./range apply` from
  different checkouts will conflict. For shared / team use, switch to a
  remote backend (Azure Storage container with state locking via
  blob lease).

### Destroying a range

```
./range destroy
```

Runs `terraform destroy` interactively. Two known slow points:

- **AFD custom-domain teardown** can take 20–60 min while Azure revokes
  the managed cert. The destroy hangs on `azurerm_cdn_frontdoor_custom_domain`
  resources — safe to leave running, or Ctrl-C and re-run later.
- **Resource-group deletion** is the last step. If anyone has manually
  added resources to a student RG (outside terraform), the RG delete
  fails and terraform leaves the RG behind in state.

If destroy hangs or errors and you just want everything gone:

```
./range nuke <range_name>
```

This finds every RG tagged `Range=<range_name>` and queues
`az group delete --no-wait` against each. Azure deletes them in the
background. After they're gone (`az group list -o table` shows them
absent), wipe the local terraform state so terraform forgets them too:

```
rm -rf envs/azure/.terraform envs/azure/terraform.tfstate*
```

### Re-applying after partial destroy

If `terraform destroy` succeeded for some resources but failed for
others, your state file has phantom entries. Two options:

- Re-run `terraform destroy` until clean (works in 90% of cases).
- For specific stuck resources, `terraform state rm
  <resource.address>` removes them from state without touching Azure.
  Use this when Azure has already deleted the resource but terraform
  is convinced it still exists.
