# terra-range on GCP — operator quickstart

Get a working cyber range deployed on Google Cloud Platform in ~45 minutes.

## What you'll get

- **One GCP project per range** — deterministic project ID derived from the
  scenario name (`redteam-lab` → `redteam-lab-75ce47`).
- **One shared "host" project** that holds your baked custom images +
  Cloud DNS zones — survives `./range destroy` cycles.
- **Atomic destroy** — `terraform destroy` cascade-deletes the whole
  per-range project (no orphaned VNets/disks to clean up manually).
- **~32% cheaper than Azure** at list price for the same `redteam-lab`
  scenario (see `scripts/quota-cost.py` — $2,286/mo vs $3,360/mo).

## Prerequisites

| Tool | Why |
|---|---|
| `gcloud` CLI | Auth, project creation, quota probes, SSH-heal pre-pass |
| `terraform` ≥ 1.6 | Provider + module |
| `packer` ≥ 1.10 (only if baking custom images) | `./range bake <target>` on GCP |
| Python 3.10+ | Generator + quota check |

| GCP-side requirement | Why |
|---|---|
| **Billing account** (`XXXXXX-XXXXXX-XXXXXX`) | Pays for the per-range project |
| **Folder OR org** (numeric ID) | Where the per-range project is nested |
| **IAM role: `roles/resourcemanager.projectCreator`** at folder/org | Lets terraform create the per-range project |
| **IAM role: `roles/billing.user`** on the billing account | Lets terraform link billing to the new project |
| **Optional: `roles/compute.imageUser`** on the host project | Lets per-range deploys read baked images |

If your org doesn't grant project-creator IAM, see **"Pre-existing project mode"** at the bottom of this doc.

## One-time setup (per GCP organization)

### 1. Auth your gcloud + Application Default Credentials

```bash
gcloud auth login
gcloud auth application-default login
```

(Terraform reads ADC; the first command authenticates `gcloud` itself.)

### 2. Create the long-lived "host" project

This project holds:
- Custom baked images (`gcloud compute images list` here)
- Cloud DNS zones for `advanced_c2` fronting

It is NEVER created or destroyed by terra-range — operator-managed.

```bash
gcloud projects create terra-range-images --folder=YOUR_FOLDER_ID
gcloud beta billing projects link terra-range-images \
    --billing-account=YOUR_BILLING_ACCOUNT_ID

gcloud config set project terra-range-images
gcloud services enable compute.googleapis.com dns.googleapis.com \
    iam.googleapis.com secretmanager.googleapis.com
```

(Replace `YOUR_FOLDER_ID` + `YOUR_BILLING_ACCOUNT_ID` with the values from
`gcloud resource-manager folders list` and `gcloud beta billing accounts list`.)

### 3. Export terra-range env vars

```bash
# Pass these to the generator so they end up in tfvars.json:
export TERRARANGE_GCP_BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"
export TERRARANGE_GCP_PARENT_FOLDER_ID="123456789012"   # or _ORG_ID="..."
export TERRARANGE_GCP_HOST_PROJECT_ID="terra-range-images"

# (Optional) override the GCP region if you don't want asia-southeast1:
export TERRARANGE_GCP_REGION="us-central1"
```

Put these in your shell rc so they persist.

### 4. Configure Marketplace EULAs (one-click in the console, per host project)

GCP Marketplace's Kali Linux image (project `kali-linux-public`) requires
manual EULA acceptance before terraform / packer can deploy from it:

1. Go to https://console.cloud.google.com/marketplace
2. Search "Kali Linux"
3. Click "Launch" or "Get started" → accept the terms
4. Same project: search "Windows Server" → accept the Microsoft terms

This is a one-time click; subsequent bakes don't re-prompt.

## Bake your images (one-time per quarter or after a major change)

Each bake takes ~20-45 min on a fresh n2-standard-4. Run unattended.

```bash
./range --provider gcp bake kali              # ~30 min — the slow one (apt + Kali metapackage)
./range --provider gcp bake adaptix           # ~25 min — Go + AdaptixC2 source build
./range --provider gcp bake mythic            # ~45 min — Docker + Mythic + 5 extra services
./range --provider gcp bake sliver            # ~5 min  — sliver-server binary download
./range --provider gcp bake ghostwriter       # ~15 min — Docker + Ghostwriter django stack
./range --provider gcp bake stepping-stones   # ~5 min  — Python venv + Django requirements
./range --provider gcp bake redelk            # ~20 min — Docker + ES + RedELK images
./range --provider gcp bake elk               # ~15 min — ES + Kibana + Logstash
./range --provider gcp bake guacamole         # ~10 min — Docker + guac images + nginx
./range --provider gcp bake debian-redirector # ~3 min  — nginx + base packages
./range --provider gcp bake win-server-2022   # ~25 min — Windows Server + AD-DS pre-install
./range --provider gcp bake win-server-2019   # ~20 min — Windows Server
./range --provider gcp bake win-server-2025   # ~25 min — newest Windows Server
./range --provider gcp bake win-10            # ~20 min — uses Server 2022 with Desktop (no client SKU on GCP)
./range --provider gcp bake win-11            # ~20 min — same fallback as win-10
```

Each bake publishes into the host project's image registry as an
**image family** — e.g., `projects/terra-range-images/global/images/family/kali-redteam`.
Re-bakes deprecate the previous version automatically; terraform's
`data.google_compute_image { most_recent = true }` reads the latest.

You can also chain them:

```bash
for t in debian-redirector sliver guacamole adaptix mythic kali \
         elk redelk ghostwriter stepping-stones \
         win-server-2022 win-server-2025 win-server-2019 win-10 win-11; do
    ./range --provider gcp bake "$t" || break
done
```

## Deploy a range

Once the bakes you need are present (or skip baking and use Marketplace fallback):

### Enable baked images in the scenario YAML

Edit `scenarios/redteam-lab.yaml` (or your scenario), set:

```yaml
baking:
  enabled: true
  use_baked_kali: true
  use_baked_adaptix: true
  use_baked_mythic: true
  use_baked_sliver: true
  use_baked_win_server_2022: true
  use_baked_win_server_2019: true
  use_baked_win_10: true
  use_baked_win_11: true
  use_baked_elk: true
  use_baked_redelk: true
  use_baked_debian_redirector: true
  use_baked_guacamole: true
  use_baked_ghostwriter: true
  use_baked_stepping_stones: true
```

Skip the `use_baked_*` flags for any image you haven't baked yet —
terraform will use the Marketplace fallback for those.

### Apply

```bash
./range --provider gcp apply redteam-lab
```

What happens:
1. Generator writes `envs/gcp/terraform.tfvars.json`
2. Preflight check (`scripts/quota-cost.py`) shows cost estimate + quota status
3. Terraform creates the per-range project (`redteam-lab-75ce47`)
4. Enables 9 GCP APIs in the project (~4 min, one-time per project)
5. Provisions VPC + subnets + firewall + Cloud NAT
6. Spins up 16 VMs from baked images (~5-8 min in parallel)
7. SSH-heal pre-pass plants operator pubkey via `gcloud add-metadata`
8. Ansible repair pass runs all 18 roles → ~10-15 min
9. Outputs Guacamole URL + admin password

Total: ~25-35 min cold deploy (with baked images).

### Destroy

```bash
./range --provider gcp destroy redteam-lab
```

This atomically deletes the per-range project (cascade-deletes every
VPC, VM, disk, firewall rule, etc. inside it). The host project +
baked images are untouched.

Re-apply lands on the SAME project ID (deterministic from `range_name`),
so it's idempotent — useful for "wiped and want to recreate" workflows.

## Cost monitoring

```bash
# Per-scenario cost + quota report:
python3 scripts/quota-cost.py

# Live billing report (after deploy):
gcloud billing accounts list                                       # find the billing account
gcloud beta billing cost-management projects describe \
    --project=redteam-lab-75ce47 --billing-account=YOUR_BILLING_ID

# Or via the console — per-project cost view at:
# https://console.cloud.google.com/billing/<account>/reports?project=redteam-lab-75ce47
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error: Project XXX not found` on first plan | Project hasn't been created yet — that's the next step in the apply (terraform creates it). If error persists at apply, check `roles/resourcemanager.projectCreator` IAM. |
| `compute.googleapis.com has not been used in project XXX` | API enablement still in progress (~30s per API × 9 APIs). Re-run `terraform apply` — terraform's dependency graph re-orders correctly. |
| `data.google_compute_image not found` | The `use_baked_X` flag is true but no image-family exists yet in the host project. Either bake it first (`./range --provider gcp bake X`) OR set the flag to false. |
| `Quota 'CPUS' exceeded` | New GCP projects start with low default quotas. Request increase via https://console.cloud.google.com/iam-admin/quotas — filter by "Compute Engine API" + `CPUS`. |
| `Permission denied (publickey)` on Guacamole RDP/SSH | SSH-heal didn't fire (no `gcloud` on PATH?). Run `./range --provider gcp repair --limit <vm>`. |
| Windows VM shows Server 2022 instead of Win 10/11 | Expected — GCP has no client SKU. Documented in `packer/win-10/win-10.gcp.pkr.hcl` header comment. |
| Managed SSL cert stuck in PROVISIONING | Normal — takes 10-30 min after DNS records resolve to the LB IP. `gcloud compute ssl-certificates describe <cert-name> --global` to poll. |

## Pre-existing project mode

If your org locks down project creation (no `projectCreator` role), have an
admin pre-create the project and set:

```yaml
# In scenarios/<your-scenario>.yaml:
gcp_project_id: "pre-existing-project-id-xyz"
gcp_create_project: false
```

Terraform skips the `google_project` + `google_project_service` resources
(`count = 0`) and uses the pre-existing project. You'll need to enable
APIs manually:

```bash
gcloud services enable compute.googleapis.com dns.googleapis.com \
    iam.googleapis.com secretmanager.googleapis.com \
    cloudresourcemanager.googleapis.com servicenetworking.googleapis.com \
    storage.googleapis.com certificatemanager.googleapis.com \
    --project=pre-existing-project-id-xyz
```

## Where to go from here

- **GCP construct mapping** (Azure→GCP equivalent for every resource):
  `docs/GCP_PARITY_ROADMAP.md`
- **Cohort / multi-student** deploys: same `students.count > 1` in YAML;
  see `scenarios/student-redteam-lab.yaml`. May need a firewall-rule
  quota bump to 500/VPC for cohorts > 5 students.
- **Shared Guacamole portal** across multiple cohorts:
  `envs/shared-guac-gcp/`.
- **Advanced C2 fronting** (External HTTPS LB + Cloud CDN + Cloud Armor):
  set `advanced_c2.enabled: true` in scenario YAML, with `domain` set
  to a registered domain whose Cloud DNS zone is in your host project.
