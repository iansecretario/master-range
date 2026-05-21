# Pre-baked images for terra-range

This directory holds Packer templates that build pre-baked images of every Windows VM type the range deploys. Pre-baked = "AD-DS, WinRM, RDP, latest Windows Updates, all-of-the-fiddly-bits already done." Cuts `./range apply` time from ~45 min to ~10 min.

## One-time setup

```bash
# 1. Install packer + the Azure plugin
brew install packer        # macOS
# or: https://developer.hashicorp.com/packer/install

# 2. Make sure your az login has Contributor on the deploy subscription
az login
az account show --query name -o tsv     # confirm right sub
```

## Bake the Server 2022 (DC) image — ~30 min, ~$0.10 of compute

```bash
./range bake server-2022
```

Watch for:
- `==> azure-arm.win22-ad: Creating Resource Group` — Packer spins up a temp build VM
- `==> azure-arm.win22-ad: Provisioning with PowerShell script` — runs baseline + WU + finalize
- `==> azure-arm.win22-ad: Capturing image` — generalizes + uploads to SIG
- Final line: `Builds finished.`

Once finished, the image is at:
```
Subscription/ResourceGroup: <your-sub>/terra-range-images-rg
Gallery: terra_range_images
Image definition: win-server-2022-ad
Image version: YYYY.MM.DD  (auto-generated from build date)
```

## Switch your scenario to use the baked image

Add this to your scenario YAML (e.g. `scenarios/redteam-lab.yaml`):

```yaml
baking:
  enabled: true
  # Defaults below are fine; leave commented unless you have a non-default gallery
  # resource_group_name: terra-range-images-rg
  # gallery_name:        terra_range_images
```

Then re-apply:

```bash
./range apply redteam-lab --domain corporaty.com --no-afd-wait
```

Terraform will see `baking.enabled: true`, look up the latest `win-server-2022-ad` version, and use `source_image_id` instead of the Marketplace `publisher/offer/sku`. Deploy time should drop to ~10-15 min.

## Re-baking (quarterly)

Windows Update releases monthly. Re-bake quarterly to get fresh patches:

```bash
./range bake server-2022
```

Each bake creates a new image version (e.g. `2026.05.11`, then `2026.08.10`). Terraform's `data.azurerm_shared_image_version.win_server_2022_ad` always picks the latest, so the next `./range apply` automatically uses the new version. Old versions are kept in the gallery until you delete them manually.

## Cost

| Item | Cost |
|---|---|
| Build VM (during bake) | ~$0.10 (30 min × D4s_v5) |
| SIG storage per image version | ~$0.50/mo (5 GB Standard_LRS) |
| Replication to extra regions | +$0.50/mo per region |

So `./range bake server-2022` once + keeping the latest version in 1 region = ~$0.60/mo recurring.

## Falling back to Marketplace

If something breaks the baked image (Packer build fails, image gets deleted, you want to test a fresh Marketplace VM):

```yaml
baking:
  enabled: false
```

Re-apply. Marketplace path kicks in transparently; no other changes needed.

## What's NOT baked yet (v1)

- `windows-server-2019` — falls back to Marketplace
- `windows-10` — falls back to Marketplace
- `windows-11` — falls back to Marketplace
- `kali` — falls back to Marketplace

Adding any of these is mechanical:
1. Copy `win-server-2022-ad.pkr.hcl` → `win-10.pkr.hcl` (or whatever)
2. Adjust `image_publisher`/`image_offer`/`image_sku` to match
3. Adjust the provisioner script for that OS family
4. Add an `azurerm_shared_image` block in `modules/azure/baking.tf`
5. Add a `baked_<os>_id` local in `images.tf`
6. Reference it in `image_map["<os>"].source_image_id`

Start with `server-2019` (member-DC) for the next biggest deploy-time win.
