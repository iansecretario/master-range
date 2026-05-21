# Scenarios

Each `.yaml` file in this directory is a **complete, self-contained scenario**.
The generator consumes one of them and produces `envs/azure/terraform.tfvars.json`;
Terraform applies that. Same module code, different inputs.

## Built-in scenarios

| File             | Shape                                              | Cost       |
| ---------------- | -------------------------------------------------- | ---------- |
| `smoke.yaml`     | 1 student, 7 boxes — fastest end-to-end test       | ~$30/day   |
| `class.yaml`     | 20 students × 10 boxes + 3 shared infra            | ~$2-3k/mo  |
| `engagement.yaml`| 5 operators × 7 boxes + AFD-fronted C2 + 2 shared  | ~$800/mo   |
| `ehvapt.yaml`    | 20 candidates × 6 boxes (2 win, 3 linux, 1 kali)   | ~$1.5-2k/mo|

## Running one

```bash
./range list                    # see what's available
./range plan smoke              # preview without applying
./range apply smoke             # gen + terraform apply
./range output                  # print URLs and where to find creds
./range lock                    # seal NAT after build
./range destroy                 # tear down
```

Or if you prefer raw commands:

```bash
python3 generator/generate.py scenarios/smoke.yaml
cd envs/azure && terraform apply
```

## Authoring a new scenario

1. Copy the closest existing scenario:
   ```bash
   cp scenarios/smoke.yaml scenarios/myrange.yaml
   ```
2. Edit the fields. The schema is documented inline in
   `generator/range.example.yaml` — every field has a comment.
3. Run it:
   ```bash
   ./range plan myrange
   ./range apply myrange
   ```

That's it. No code changes needed; Terraform doesn't know which scenario
is active — it only sees the resulting `terraform.tfvars.json`.

## What the YAML controls

- **`students.count`** — how many isolated copies of the machine template to clone
- **`machines:`** — the per-student template (every student gets one of each)
- **`shared_infrastructure:`** — boxes deployed ONCE in the hub (not per student)
- **`advanced_c2:`** — turn on Azure Front Door fronting the C2 chain
- **`lockdown:`** — `false` for build-time internet, `true` to seal egress
- **`services.{guacamole,elk,adaptix,redirector}.enabled`** — individually toggle
  hub services and bootstrap behaviour. Disable ELK if your scenario doesn't
  ship logs (e.g. `ehvapt.yaml`); disable Adaptix if you don't have C2 boxes.

## Per-scenario notes

### `smoke.yaml`
Use this first. If `terraform apply` survives a single-student run, the larger
scenarios will work — they're just the same shape with more clones.

### `class.yaml`
Watch the bill: NAT gateway alone is ~$32/mo per student (×20 = $640/mo). After
the first apply has settled (~25 min), run `./range lock` to tear the NAT down.

### `engagement.yaml`
Requires:
- Azure DNS zone for `enterprisestudio.com` already exists in RG `dns-rg`
- Registrar nameservers point at the Azure DNS zone
- Marketplace terms accepted for Kali (and Win10/11 if your machine list uses them)

After apply, AFD custom-domain validation lags DNS propagation by 5-15 min. The
route exists but returns 404 until validation completes. `terraform output -json
advanced_c2` shows the per-operator domains.

### `ehvapt.yaml`
- ELK and Adaptix disabled — exam candidates bring their own tooling on Kali
- 2 Windows (DC + member) + 3 Linux (web/app/db) gives a realistic mixed-OS
  pivot scenario
- Distribute candidate creds with `terraform output -json student_logins`
