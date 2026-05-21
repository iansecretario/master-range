# In-depth review

Findings from a full pass over the generator, Azure module, bootstrap
scripts, and architectural assumptions. Items are graded by impact:

- **CRITICAL** — would break `terraform apply` or cause silent drift on every plan
- **HIGH** — silent runtime bug, won't fail plan but won't behave as intended
- **MEDIUM** — works as built but creates ops pain or weakens hygiene
- **LOW** — polish, future enhancement

Critical and High items are fixed in this commit. Medium/Low are
documented for follow-up.

---

## CRITICAL

### C1. NSG inline-rule + standalone-rule conflict
**Status: FIXED**

`students.tf` declares `azurerm_network_security_group.attacker` with
inline `security_rule {}` blocks. `frontdoor.tf` adds an
`azurerm_network_security_rule.afd_to_redirector` that targets the same
NSG. The azurerm provider treats inline rules as the source of truth and
removes any standalone rule on every plan, while the standalone resource
re-adds itself — Terraform fights itself forever.

**Fix:** delete the standalone rule. Add a `dynamic "security_rule"`
block to the inline NSG, conditional on `var.advanced_c2.enabled`. The
rule destination is pinned to `10.<n>.1.6/32` (the redirector's static
IP), so Kali / c2-server in the same subnet are unaffected.

### C2. Single-c2-server / single-c2-redirector enforcement missing
**Status: FIXED**

`vms.tf` pins `c2-server` to `10.<n>.1.5` and `c2-redirector` to
`10.<n>.1.6`. If a YAML defines two of either, both NICs try to claim
the same private IP and the second VM fails to create. Currently the
generator only enforces single `windows-dc`.

**Fix:** add the same uniqueness check for `c2-server` and
`c2-redirector` in `validate()`.

---

## HIGH

### H1. ELK password hard-coded in agent configs
**Status: FIXED**

`linux-target.sh`, `windows-dc.ps1`, and `windows-member.ps1` all hard-
code `"ChangeMe!Elk1"` for the elastic user. If the operator sets a
different `services.elk.kibana_password` in YAML, every agent fails to
authenticate to Elasticsearch.

**Fix:** thread `kibana_password` through `templatefile()` calls in
`vms.tf` for all three scripts. Already passed; just plumbing.

### H2. Guacamole `register.py` deadlocks on second run
**Status: FIXED**

The script logs in as `guacadmin/guacadmin`, rotates the password to
the configured one, then re-logs in. If the script is re-run after a
successful first run, the default-password login retries 60 times then
exits — `terraform apply` then succeeds but the VM's bootstrap log
shows registration failure.

**Fix:** try the configured admin password first; fall back to default
only if that fails. Idempotent.

### H3. AdaptixC2 systemd unit starts even when build fails
**Status: FIXED**

`c2-server.sh` runs `make server || go build … || true` and then
unconditionally enables the systemd unit. If both fail, systemd loops
forever on a missing binary, generating noise and masking the real error.

**Fix:** verify the binary exists and is executable before enabling
the unit. Log a clear failure message otherwise.

### H4. `register.py` runs only once via cloud-init
**Status: ACCEPTED**

If new students are added later, the Guacamole VM doesn't re-render
its manifest unless the VM is recreated. Re-running register.py with
a fresh manifest registers new connections idempotently, but there's
no automatic trigger.

**Mitigation:** A standalone `scripts/guac-resync.py` helper that
operators can run from their workstation against the live Guacamole
API. This is documented as a follow-up; the current model (rebuild
hub when student count changes) works for class-cycle workflows.

---

## MEDIUM

### M1. ELK VM admin password reuses Kibana password
The hub ELK VM is created with `admin_password = kibana_password`.
If the operator picks a Kibana password too short for Azure VM
complexity (8-123 chars + 3 of {upper, lower, digit, special}), the
VM fails to create with a generic error.

**Recommendation:** generate the VM admin password via
`random_password` and keep `kibana_password` strictly for ES auth.

### M2. Cloud-init logs may leak passwords
`/var/log/cloud-init-output.log` retains the rendered userdata. Anyone
who SSHes into a target with sudo can read every password used at
provisioning time.

**Mitigation:** add a final cloud-init step that scrubs the log:
`sed -i 's/plain_text_passwd:.*/plain_text_passwd: REDACTED/'
/var/log/cloud-init-output.log`. Doesn't catch nginx config
passwords; for those, write secrets to root-only files.

### M3. Marketplace terms acceptance is manual
`az vm image terms accept` must run once per subscription per image.
Documented in the README but easy to miss; failed apply gives a
cryptic error.

**Recommendation:** add `null_resource` + `local-exec` in the module
that runs `az vm image terms show` to verify acceptance and fails
fast with a useful message. (Adds az-cli dependency to the operator
workstation.)

### M4. AFD custom-domain validation timing
After apply, AFD validates each custom domain by reading the
`_dnsauth.<host>` TXT record. Validation can lag DNS propagation by
5-15 minutes. During that window the route exists but returns 404
to clients. There's no Terraform-side wait for "domain validated".

**Mitigation:** documented in the README. For automation, a `time_sleep`
+ `azurerm_cdn_frontdoor_custom_domain` data source poll is doable
but adds complexity; defer until needed.

### M5. NAT gateway cost when `lockdown=false`
Standard NAT Gateway is ~$32/mo per student (20 = $640/mo). If
operators forget to flip `lockdown=true` after build, the bill
spirals.

**Recommendation:** add a `lockdown_after_minutes` field that triggers
NAT teardown automatically via a `time_sleep` resource. Out of scope
here but worth a script.

### M6. Per-student creds are template-shared
Every student's `corp.local` Domain Admin has the same password
(`P@ssw0rd!RangeAdmin1`). VNets are isolated so cross-student access
isn't possible, but for grading scenarios where students might compare
notes, randomize per student.

**Recommendation:** generate `domain.admin_password` per student via
`random_password` keyed on student_id; surface via outputs.

### M7. Quota / limits ceiling
At 20 students × 10 machines, the range eats ~100 cores. Default
Azure quota for B-series in a region is often 50-100. AFD Standard
caps at 25 custom domains per profile (we use 20 for 20 students;
30 students would need Premium SKU or a second profile).

**Documented:** README mentions quota generally; link to the AFD
limit table is a follow-up.

---

## LOW

### L1. No Adaptix-client connection info in outputs
After deploy, operators have to look up each student's c2-server IP
to give to learners. Add a structured `adaptix_connections` output:
`{ student_id, ip, port, password }` per student.
**Status: FIXED** (added to outputs.tf).

### L2. Shared-infra credentials not in outputs
`shared_infra` output gives the public IP and SSH user but not the
password. Add a sensitive output.
**Status: FIXED**.

### L3. Sysmon config pulled from GitHub at runtime
`SwiftOnSecurity/sysmon-config` is fetched from `master`. For
reproducibility pin to a specific commit. Low priority; the Sysmon
config rarely breaks in non-backwards-compatible ways.

### L4. No host firewall on hub VMs
NSGs do the gating, but iptables/ufw would add defense in depth.
Acceptable for a teaching range.

### L5. Marketplace `plan {}` on Win10/11
Always set, but only required when the operator hasn't accepted
terms via VS subscription benefit. Harmless when not needed.

### L6. AFD WAF / geo-restrictions unavailable in Standard SKU
For realistic red-team setups, WAF rules and geo-blocking are
useful. Premium SKU has them; Standard doesn't. Document in the
advanced_c2 section; switching SKU is one variable.

### L7. RedELK shipper config not auto-deployed
The c2-server and c2-redirector ship logs to RedELK in real
deployments. The boxes are wired up in the same broadcast domain
(hub <-> students peering), but Filebeat configs aren't templated
yet. Operator runs RedELK's `initial-setup.sh`, gets the cert/config,
copies to each shipper. Documented; auto-deployment is a future task.

### L8. Per-student randomization of attacker creds
All students share the same Kali / c2 / redirector credentials. For
class hygiene this is fine (operator-side anyway). For red-team-vs-
red-team scenarios, randomize.

---

## Verified-clean items

- HCL syntax: hand-reviewed; no comma-as-arg-separator bugs, no
  `count`+`for_each` collisions, no orphaned resource references
- Cross-file refs: `local.machine_public_ip` (vms.tf) →
  `azurerm_public_ip.redirector` (frontdoor.tf) resolves through
  Terraform's dependency graph; no cycle
- `try()` guards `count = 0` access in vms.tf when AFD disabled
- DC RunOnce / phase-2 reboot pattern: phase-1 returns 0 to CSE
  before `shutdown /r /t 60` fires; CSE reports Succeeded
- Generator handles single-student vs multi-student static_ip
  rebasing correctly (validated: `s01-dc01` lands at `10.1.0.10`)
- Resource naming under all Azure max-length limits
- Subnet NSG rule priorities don't collide

---

## What I still can't validate

This container has no internet egress, so `terraform init` and
`terraform validate` cannot run against the azurerm provider.
Everything above is hand-reviewed. Run

    cd envs/azure
    terraform fmt -recursive ../../modules
    terraform init
    terraform validate

before your first deploy and ping me on anything it surfaces.
