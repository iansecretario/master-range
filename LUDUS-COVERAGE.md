# Ludus environment guides — coverage map

[Ludus](https://docs.ludus.cloud/docs/category/environment-guides) ships a
catalogue of named lab scenarios (GOAD, ADCS, Vulhub, Splunk Attack Range,
SCCM, BarbHack CTF, etc.) that they install on top of base Proxmox templates
via ansible roles.

Our equivalent: scenario YAMLs in `scenarios/` + per-VM configuration scripts
in `personas/`. Same idea, different orchestration substrate (Terraform +
cloud-init + CSE instead of Proxmox + ansible).

## Coverage status

| Ludus scenario | Status | Our equivalent |
| --- | --- | --- |
| Basic Active Directory Network | ✅ Built-in | Any scenario with `domain.enabled: true` + `windows-dc` + `windows-member` boxes |
| Vulhub | ✅ `scenarios/vulhub.yaml` | `personas/vulhub.sh` clones the Vulhub repo and starts a configurable list of CVE labs |
| ADCS | ✅ `scenarios/adcs.yaml` | `personas/adcs.ps1` installs Enterprise CA + ESC1/ESC2 vulnerable templates on a domain-joined member |
| Splunk Attack Range | ✅ `scenarios/splunk-ar.yaml` | `personas/splunk-server.sh` (indexer) + `personas/splunk-uf.ps1` (Windows UF + Sysmon) |
| Elastic Security | ⚠️ Partial | `services.elk` already deploys ES + Kibana to the hub; agent shipping covers the basics. A dedicated `personas/elastic-fleet.sh` for the full Elastic Security experience would be a good next add. |
| Game of Active Directory (GOAD) | ✅ `scenarios/goad.yaml` + `scripts/goad-ansible-bridge.sh` | Five-VM topology (3 DCs + 1 member + 1 Kali) with **fully customisable** identities — domain FQDNs, NetBIOS hostnames, domain admins, full user roster, full service-account roster, vuln-config toggles. The bridge script reads the scenario YAML + `terraform output` and emits a GOAD-compatible ansible inventory + `group_vars/all.yml` that overrides upstream identities, then you run `ansible-playbook` against the upstream `Orange-Cyberdefense/GOAD` repo. |
| GOAD-Light, GOAD-DRACARYS, GOAD-NHA, GOAD-SCCM | 🔶 Variants of GOAD | Same approach — start from `scenarios/goad.yaml`, drop unused boxes / customise the goad: block, point bridge script at the variant's playbook. The bridge generates the right inventory regardless of variant. |
| SCCM Lab | 🔶 Topology only | SCCM site server + DP + clients. Single-box install is doable as a Windows persona; full site config (boundary groups, package distribution, client push) needs cross-VM orchestration. |
| BarbHack CTF 2024 (Gotham City) | 🔶 Could be ported | The upstream is an ansible playbook against the Ludus lab; would need to be re-implemented as personas. Mid-effort. |
| NetExec Workshop (leHACK 2024 / 2025) | 🔶 Could be ported | Same shape as BarbHack — workshop-specific multi-VM config. |
| SANS Workshops (AD Privesc / Shadow Steps) | 🔶 Could be ported | Same; depends on whether the source ansible can be cleanly translated into per-VM personas. |
| Pivot Lab | 🔶 Topology gap | Needs ≥3 network segments (DMZ → internal → restricted). Our current model is 2 subnets per student (targets + attacker). Adding a `segments:` field to the YAML would close this. |
| Malware Lab (xz backdoor) | 🟡 Single-box doable | A `personas/xz-backdoor.sh` that builds the patched openssh and replays the supply-chain backdoor would work. Not built yet. |

Legend: ✅ ready · ⚠️ partial · 🔶 needs more module work · 🟡 easy to add

## Building GOAD on top

The natural way to add GOAD-style multi-VM scenarios:

1. **Topology in the scenario YAML**: define the right DCs and members,
   roles, and domain settings.
2. **Per-VM personas as before**: each DC gets a `goad-rootdc.ps1` /
   `goad-childdc.ps1` persona that installs the role, configures the
   domain, sets up the trust direction, and seeds users.
3. **Coordination via DNS + ordering**: child DCs poll for the root DC's
   `_ldap._tcp.dc._msdcs` SRV record before joining (same pattern our
   `windows-member.ps1` uses today). Members poll for their DC.
4. **Vulnerable-config personas**: add `personas/goad-vulns.ps1` that
   runs after the forest is built and seeds Kerberoastable accounts,
   ACL misconfigs, GPO weaknesses.

This is doable but is a significant chunk of work — GOAD's upstream
ansible is ~5000 lines across many roles. A cleaner near-term option
is to publish a `scenarios/goad-skeleton.yaml` that gets the **topology
right** and lets the operator run the upstream GOAD ansible playbook
against the resulting Azure VMs (via WinRM/SSH inventory). That's
~100 lines of work and produces a working GOAD; we just don't own the
configuration playbooks.

## Wiring an upstream ansible playbook

If you want to reproduce a Ludus scenario whose ansible source is on
GitHub, the bridge is:

1. Generate the topology with our generator:
   ```bash
   ./range apply <scenario>
   ```
2. Pull the public IPs / private IPs from outputs:
   ```bash
   terraform output -json machine_ips
   ```
3. Build an ansible inventory from those, then run the upstream playbook:
   ```bash
   ansible-playbook -i inventory.ini upstream-playbook.yml
   ```

A future helper script (`scripts/gen-ansible-inventory.sh`) could do
step 2 → 3 automatically. It's on the medium-priority backlog.

## Authoring a new Ludus-equivalent persona

For a Ludus environment that's a **single-box configuration** (not
multi-VM coordination), the recipe is:

1. Read the upstream ansible role / project README.
2. Translate the ansible tasks into a single bash (Linux) or
   PowerShell (Windows) script that's idempotent and one-shot.
3. Save as `personas/<name>.sh` or `personas/<name>.ps1`.
4. Reference from a scenario YAML:
   ```yaml
   - { name: thing, role: linux-target, os: debian-12, persona: <name> }
   ```
5. Test with `./range plan <scenario>`.

Most of the simpler Ludus scenarios fit this mould.
