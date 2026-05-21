# terra-range Roadmap

Forward-looking design doc covering the next planned architectural work and a
prioritized backlog of operational gaps. Each section is self-contained — you
can read just the one you care about.

Last updated: 2026-05-15.

---

## Table of contents

1. [Multi-instance architecture (`--mode shared|isolated`)](#1-multi-instance-architecture) — primary upcoming work, scoped to the `redteam-lab` scenario
2. [Backlog: operational gaps](#2-backlog-operational-gaps) — discrete improvements, ranked
3. [Known risks on first apply](#3-known-risks-on-first-apply) — informational, no action needed
4. [Phasing recommendation](#4-phasing-recommendation) — suggested order

---

## 1. Multi-instance architecture

### Problem

Today's terra-range deploys ONE range per `terraform apply`: one resource
group, one VNet, one Guacamole, one AFD profile, one DNS subdomain per
redirector. The existing `students[]` array supports multiple students sharing
that single range — they each get their own subnet, their own Guacamole user,
and their own RDP credentials — but everything else is shared (DC, kali,
teamservers, AFD).

### The two deployment modes

Operators pick one of two modes at deploy time, by name. The split is
along a single clean axis: **is the *target* infrastructure shared, or is
every student in their own range?**

#### `shared` — shared targets, per-student attacker kit

> **Definition**: a single deployment where all students attack the SAME
> target infrastructure (one DC, one set of member servers / workstations
> / analyst / linux01), but each student gets their OWN attacker kit
> (their own kali VM, their own C2 teamservers, their own C2 redirectors).
> Guacamole, AFD, parent DNS, and the target VNet are shared across all
> students.

What's shared (one set, every student uses these):
- **Guacamole VM** — students log in here; each gets their own Guac user
  and per-student connection group
- **Target Windows lab** — DC (`dc01`), member server (`srv01`),
  workstations (`ws10`, `ws11`), analyst (`analyst`), Linux target
  (`linux01`)
- **AFD profile + parent DNS zone** — one of each, with per-student
  endpoint subdomains
- **Hub VNet** (guac sits here)

What's per-student (one PER student, with their student-id in the name):
- **Kali attacker workstation** — `kali-${student}`, full kali + tools +
  XFCE + xrdp
- **C2 teamservers** — `adaptix-${student}`, `mythic-${student}`,
  `sliver-${student}`, (`brc4-${student}` if licensed)
- **C2 redirectors** — `adaptix-redir-${student}`, etc., with their own
  AFD endpoints (so each student's beacon binary points at their own
  `.azurefd.net` hostname)

Layout: one resource group, one VNet, three classes of subnet:
- `hub` (10.X.0.0/16): shared services (guac)
- `targets` (10.X.1.0/24): shared target lab — every student SSHes /
  RDPs into the same boxes
- `attacker-${student}` (10.X.${N}.0/24 per student, N=2..17): per-student
  attacker kit, NSG-isolated so students can't see each other's kali

When a student RDPs into their kali via Guacamole and runs a payload that
beacons home, it traverses: `kali-alice` → `adaptix-alice` (teamserver)
via the `adaptix-redir-alice` redirector via AFD. Their teammates' kalis
are NOT in their network path; the only thing they share is the *target*
they're attacking on the other side of the VNet.

- Cost: 1× shared core + N × per-student attacker stack ≈ 3-5× single deploy
  for 10 students (the attacker stack is the bulk of the cost; targets are
  cheap relative to a kali + 3-4 teamservers + 3-4 redirectors).
- Failure isolation: one student crashing their kali / C2 can't affect any
  other student. A target-side failure (e.g. DC down) affects everyone.
- Operator simplicity: one `./range repair` reconfigures everything; one
  Guacamole UI with N student logins.

**CLI:** `./range up --mode shared --count 10`

#### `isolated` — full per-student range, nothing shared

> **Definition**: N completely independent deployments rendered from the
> same scenario. Each student gets their OWN resource group, VNet, guac,
> kali, teamservers, redirectors, AFD, DC, target Windows lab — every VM.
> No shared anything other than the parent Azure subscription and the
> parent DNS zone (`enterprisesstudio.com`).

- N resource groups, N VNets, N Guacamoles.
- Per-student failure isolation is total: a student can blow up their
  range, their AD, their everything, and no other student is affected.
- A student CAN'T see another student's range at all — separate Guac UI,
  separate DNS subdomains (`isolated-NN.enterprisesstudio.com`), separate
  Azure resources.
- Most expensive: ~10× the cost of `shared` for 10 students (because the
  target lab is duplicated N times in addition to the attacker kit).
- Operator complexity: N separate Guacamoles (each student gets their own
  magic-link URL); `./range repair --instance all` fans out.

**CLI:** `./range up --mode isolated --count 10`

### How the two modes compare

| | `shared` | `isolated` |
|---|---|---|
| **Resource groups** | 1 | N |
| **VNets** | 1 | N |
| **Guacamole VMs** | 1 (one URL, N student users) | N (one URL per student) |
| **Kali VMs** | N (one per student) | N (one per student) |
| **C2 teamserver VMs** | N each (per-student adaptix/mythic/sliver/brc4) | N each (per-student adaptix/mythic/sliver/brc4) |
| **C2 redirector VMs** | N each (per-student) | N each (per-student) |
| **Target Windows lab (DC, srv01, ws10, ws11, analyst)** | 1 set, shared | N sets, per-student |
| **linux01 target** | 1, shared | N, per-student |
| **AFD profile** | 1 (shared) | N (one per range) |
| **DNS namespace** | flat under parent zone, per-student endpoint subdomains | `isolated-NN.<parent zone>` |
| **Per-student attacker isolation** | NSG-enforced; students can't see each other's kali / C2 | total (separate VNet entirely) |
| **Per-student target isolation** | none — everyone attacks the same DC | total |
| **Cost (10 seats)** | ~3-5× single deploy | ~10× single deploy |
| **Pick when** | training cohort where students should attack the SAME corporate AD (shared learning environment) | cohort where each student needs full sovereignty — their own AD, their own everything, no observable interaction with others |

### How to pick

```
Should every student attack the SAME corporate AD / target lab?
├─ Yes → shared    (cheaper, simpler operator surface, shared learning environment)
└─ No  → isolated  (full sovereignty per student, ~2-3× the cost)
```

Quick rules of thumb:
- **Solo operator / dev range** → no flag (today's behavior; single deploy)
- **Classroom / cohort training where the lesson is "attack THIS AD"** → `shared`
- **Customer engagement / per-tenant deployment where each tenant must be a sealed box** → `isolated`
- **Bug bounty / CTF where targets should be identical but students mustn't collude** → `isolated`

### Decision is reversible

You can rebuild a range as a different mode without scenario changes —
each mode reads the same scenario YAML and just lays out the resources
differently. So if you start with `shared` and outgrow it, destroy +
re-apply as `isolated` and the operator workflow is identical.

### Implementation design

Scoped to the **`redteam-lab` scenario** (this section), which is the only
multi-student scenario in the codebase today. Other scenarios (`vulhub`,
solo-operator dev scenarios) keep their current single-deploy behavior
unchanged — they're not used in a cohort context.

The redteam-lab scenario today has 13 machines:

| Class | Machine | Today | After `shared` mode |
|---|---|---|---|
| **Target lab** | `dc01` | 1 | 1 (shared across all students) |
| | `srv01` | 1 | 1 (shared) |
| | `ws10` | 1 | 1 (shared) |
| | `ws11` | 1 | 1 (shared) |
| | `analyst` | 1 | 1 (shared) |
| | `linux01` | 1 | 1 (shared) |
| **Attacker kit** | `kali` | 1 | **N** (one per student) |
| | `adaptix` | 1 | **N** (one per student) |
| | `adaptix-redir` | 1 | **N** (one per student) |
| | `mythic` | 1 | **N** (one per student) |
| | `mythic-redir` | 1 | **N** (one per student) |
| | `sliver` | 1 | **N** (one per student) |
| | `sliver-redir` | 1 | **N** (one per student) |

The `students[]` array in `terraform.tfvars.json` is the source of truth for
"how many seats". The machines schema gets a new field — `per_student: bool`
— that controls whether the machine is duplicated N times or stays at
quantity 1.

#### File layout

`isolated` uses env-dir-per-instance; `shared` uses the single env dir.

```
envs/
  azure/                         # default + `shared` home
    main.tf                      # symlink → ../_shared/main.tf
    terraform.tfvars.json
    .active-scenario
  _shared/
    main.tf                      # shared module invocation
  isolated-01-azure/             # `isolated`: one env dir per instance
    main.tf                      # symlink → ../_shared/main.tf
    terraform.tfvars.json        # range_name=isolated-01, isolated CIDRs, students=[1]
    .active-scenario
  isolated-02-azure/
  ...
```

Each instance dir is a self-contained terraform workspace with its own
`terraform.tfstate`. The `main.tf` symlink to `_shared/main.tf` means a
code change to the underlying module hits every dir on next apply — no
need to manually sync N directories.

**Why not terraform workspaces?** Workspaces share `main.tf` and split state,
which sounds right, but they make `terraform output` per-workspace ergonomics
worse (you have to `terraform workspace select` first) and don't give you a
distinct dir to `cd` into per deployment. Env-dir-per-deployment matches the
existing mental model that "an env dir IS a deploy."

**Mode-specific notes:**
- **`shared`**: no new env dirs. The generator expands the
  `redteam-lab` scenario's machine list — every machine marked
  `per_student: true` (kali + the 6 C2 VMs) gets templated N times into
  `terraform.tfvars.json`'s `machines[]`, with names like
  `kali-alice / kali-bob / kali-carol / ...`. The shared targets stay at
  quantity 1. The existing per-student subnet / Guac user logic stitches
  each student's Guac connections to their own attacker kit.
- **`isolated`**: N env dirs `isolated-NN-azure/`. Each is a complete
  range (every machine at quantity 1, single-student schema). No peering
  between instances. Each has its own AFD, DC, guac.

#### CIDR allocation strategy

Each instance owns a `/14` block (4 contiguous `/16`s), large enough for
spoke expansion when `--students-per-instance` is large:

| Instance | CIDR block | Hub | Spoke (carved per-student) |
|---|---|---|---|
| inst-01 | 10.4.0.0/14 | 10.4.0.0/16 | 10.5.0.0/16 (students get /20s within) |
| inst-02 | 10.8.0.0/14 | 10.8.0.0/16 | 10.9.0.0/16 |
| inst-03 | 10.12.0.0/14 | 10.12.0.0/16 | 10.13.0.0/16 |
| … | (skipping 4 /16s per instance) | | |
| inst-63 | 10.252.0.0/14 | 10.252.0.0/16 | 10.253.0.0/16 |

For `shared` mode in the redteam-lab scenario, each student needs their
own attacker subnet inside the spoke. Students get a `/24` each (room for
~10 attacker VMs comfortably — kali + 3 teamservers + 3 redirectors + headroom),
allocated like:

| Student index | Attacker subnet | Hosts |
|---|---|---|
| 1 (alice) | 10.1.10.0/24 | `kali-alice` (10.1.10.20), `adaptix-alice` (10.1.10.5), `adaptix-redir-alice` (10.1.10.6), `mythic-alice` (10.1.10.7), etc. |
| 2 (bob) | 10.1.11.0/24 | `kali-bob` (10.1.11.20), `adaptix-bob` (10.1.11.5), ... |
| ... | ... | ... |
| 16 (max) | 10.1.25.0/24 | |

The shared target subnet stays at `10.1.0.0/24` (dc01 / srv01 / ws10 /
ws11 / analyst / linux01). 16-student ceiling per `shared` range fits
comfortably in the existing `/16` spoke.

Capacity envelope:
- 63 instances inside 10.0.0.0/8 (`isolated` mode)
- 16 students per `shared` range (subnet allocation limit)
- For >16 students with shared targets, you'd run two `shared` ranges
  (each with their own DC + lab). Or move to `isolated`.

Algorithm in the generator:

```python
def cidrs_for(instance_idx, students_per_instance):
    """instance_idx is 1-based for inst-NN; 0 means single-deploy default."""
    if instance_idx == 0:
        return {"hub": "10.0.0.0/16", "spoke": "10.1.0.0/16"}
    second_octet = instance_idx * 4
    return {
        "hub":   f"10.{second_octet}.0.0/16",
        "spoke": f"10.{second_octet + 1}.0.0/16",
    }
```

#### Range-script command surface

The CLI is scenario-aware: `--mode shared` only applies to scenarios that
declare per-student machines (today: just `redteam-lab`). For other
scenarios it's a no-op equivalent to today's single-deploy behavior.

```bash
# `shared` — 10 students in one redteam-lab range, sharing dc01/srv01/etc.
# but each getting their own kali + C2 stack
./range up --mode shared --count 10 --scenario redteam-lab

# `isolated` — 10 independent redteam-lab ranges, every student gets a full kit
./range up --mode isolated --count 10 --scenario redteam-lab

# Default — single-deploy (today's behavior; equivalent to --mode shared --count 1)
./range up                                                  # uses .active-scenario
./range up --scenario redteam-lab                           # one student, one range, all in envs/azure/

# Operate on existing isolated instances
./range repair  --instance isolated-03                     # one specific instance
./range repair  --instance all                             # fan out to every isolated instance
./range creds   --instance isolated-07                     # creds (incl. magic link) for one instance
./range creds   --instance all                             # one block per instance
./range destroy --instance isolated-04
./range destroy --instance all                             # tears down every isolated-NN env dir
./range health  --instance all                             # requires `./range health` (see §2.1)

# `shared` operations target the default envs/azure/ dir (no --instance flag needed)
./range repair                                             # repairs ALL students in the shared range
./range repair --student alice                             # only re-converge alice's attacker kit
./range creds                                              # prints magic links for every student in the shared range
./range creds --student alice                              # only alice's block
./range destroy                                            # destroys the whole shared range
```

**Flag semantics summary:**

| Flag | Used by | Meaning |
|---|---|---|
| `--mode {shared,isolated}` | `up` only | which deployment shape to create |
| `--count N` | `up` only | for `shared`: number of students; for `isolated`: number of env dirs |
| `--scenario <name>` | `up` only | which scenario YAML to render (today: `redteam-lab`, `vulhub`, etc.) |
| `--instance <name>` | every subcommand except `up`, only for `isolated` mode | operate on this specific isolated instance; e.g. `isolated-03` |
| `--instance all` | every subcommand except `up` | fan out to every existing `isolated-NN` env dir |
| `--student <id>` | every subcommand except `up`, only for `shared` mode | scope the operation to one student's attacker kit |
| (no flag) | every subcommand | operate on `envs/azure/` (single-deploy / `shared` home) |

Backward compatibility: every existing command continues to work
bit-for-bit identically when no `--mode` / `--instance` / `--student` flag
is given. The default code path is unchanged — `./range up` still produces
a single shared deployment in `envs/azure/`.

#### DNS strategy

Single shared parent zone `enterprisesstudio.com`. Records are
instance-namespaced:

```
adaptix-redir.inst-01.enterprisesstudio.com   CNAME   <afd endpoint>.azurefd.net
mythic-redir.inst-01.enterprisesstudio.com    CNAME   <afd endpoint>.azurefd.net
sliver-redir.inst-01.enterprisesstudio.com    CNAME   <afd endpoint>.azurefd.net
...
adaptix-redir.inst-10.enterprisesstudio.com   CNAME   <afd endpoint>.azurefd.net
```

This keeps DNS management centralized while giving each instance a clean
namespace. Per-redirector AFD endpoints already deliver the
custom-domain-hidden-from-beacon-binary property (the operator-facing name
is `inst-NN.enterprisesstudio.com`; the beacon binary callbacks at the AFD
`*.azurefd.net` endpoint hostname only).

For the Guac UI hostname: `guac.inst-NN.cyberwarrange.com` (or
`cwr-<random>-inst-NN.cyberwarrange.com` if you keep the existing
random-suffix convention).

#### Parallelism orchestration

```bash
./range up --instance 10
```

internally:

```bash
for i in 01 02 03 ... 10; do
  render_env_dir inst-$i
done
parallel -j 4 'cd envs/inst-{}-azure && terraform apply -auto-approve' ::: 01..10
```

Throttled at `-j 4` (or `--parallelism N`) to avoid Azure API throttling
(`Microsoft.Network` ARM PUTs get rate-limited around 1000/hour per
subscription). 10 instances × ~200 PUTs each = 2000 PUTs; serialized would
hit the limit late in the run. 4-way parallel keeps each instance below the
per-subscription budget while still completing 10 instances in ~25 min
(vs 200 min serialized).

#### Cost model (rough, Azure East US, Spot pricing)

Single range ≈ $X/day (kali B4ms + 4× Windows + 3× C2 + 3× redirector + guac
+ shared infra). 10 instances ≈ 10×X/day. Mitigations:
- `--pause` mode (see §2.8) deallocates VMs at night.
- Spot VMs default everywhere except DC (eviction would break the lab).
- Shared image gallery (existing) keeps boot-disk cost flat across instances.

### Worked example: `./range up --mode shared --count 10 --scenario redteam-lab`

This is what the generator emits and terraform creates when you run the
above command. Concrete to make the design unambiguous.

#### What the generator does

Reads `scenarios/redteam-lab.yaml`, identifies machines flagged
`per_student: true`, and templates them per-student. Emits one
`envs/azure/terraform.tfvars.json`:

```json
{
  "range_name": "redteam-lab-shared",
  "students": [
    {"username": "alice",  "netbios": "corporaty"},
    {"username": "bob",    "netbios": "corporaty"},
    {"username": "carol",  "netbios": "corporaty"},
    ...
    {"username": "jenny",  "netbios": "corporaty"}
  ],
  "machines": [
    /* SHARED TARGETS — quantity 1, every student attacks these */
    {"name": "dc01",      "role": "windows-dc",          ...},
    {"name": "srv01",     "role": "windows-member",      ...},
    {"name": "ws10",      "role": "windows-workstation", "assigned_user": null, ...},
    {"name": "ws11",      "role": "windows-workstation", "assigned_user": null, ...},
    {"name": "analyst",   "role": "windows-analyst",     ...},
    {"name": "linux01",   "role": "linux-target",        ...},

    /* PER-STUDENT ATTACKER KIT — quantity 10, one set per student */
    {"name": "kali-alice",          "role": "attacker",        "student_id": "alice",  ...},
    {"name": "adaptix-alice",       "role": "c2-server",       "student_id": "alice",  ...},
    {"name": "adaptix-redir-alice", "role": "c2-redirector",   "student_id": "alice",  ...},
    {"name": "mythic-alice",        "role": "c2-mythic",       "student_id": "alice",  ...},
    {"name": "mythic-redir-alice",  "role": "c2-redirector",   "student_id": "alice",  ...},
    {"name": "sliver-alice",        "role": "c2-sliver",       "student_id": "alice",  ...},
    {"name": "sliver-redir-alice",  "role": "c2-redirector",   "student_id": "alice",  ...},
    {"name": "kali-bob",            "role": "attacker",        "student_id": "bob",    ...},
    /* ... 6 more per-student machines for bob ... */
    /* ... 7 per-student machines × 8 more students (carol..jenny) ... */
  ]
}
```

Total machines: 6 (shared targets) + 7 × 10 (attacker kit per student) = **76 VMs**.

#### What Azure ends up with

One resource group `redteam-lab-shared-rg` containing:

- **1 hub VNet** `10.0.0.0/16` (guac sits here at 10.0.0.20)
- **1 spoke VNet** `10.1.0.0/16` peered to hub, carved into:
  - `targets` subnet `10.1.0.0/24` — dc01 (10.1.0.10), srv01 (10.1.0.6),
    ws10 (10.1.0.4), ws11 (10.1.0.5), analyst (10.1.0.11), linux01 (10.1.0.7)
  - `attacker-alice` subnet `10.1.10.0/24` — alice's 7 VMs
  - `attacker-bob` subnet `10.1.11.0/24` — bob's 7 VMs
  - ... through `attacker-jenny` at `10.1.19.0/24`
- **Per-student NSGs**: each attacker subnet has its own NSG that allows
  outbound to the `targets` subnet (so alice can attack dc01) and outbound
  to AFD for beaconing, but DENIES inbound from other attacker subnets
  (alice can't see bob's kali)
- **1 Guacamole VM** with 10 student users (alice/bob/.../jenny), each
  granted READ on their own connection group:
  - `alice's range/`
    - `kali-alice` (RDP/3389)
    - `dc01` (RDP/3389 — shared target, alice has rangeadmin creds)
    - `srv01 (alice@corporaty)` (RDP/3389 — alice's domain login)
    - `ws10` (RDP — alice gets her own assigned user)
    - `linux01 (alice)` (SSH/22)
    - `adaptix-alice` (SSH/22)
    - `mythic-alice` (SSH/22)
    - `sliver-alice` (SSH/22)
  - `bob's range/` — same shape, bob's attacker kit + alias to same targets
  - ... × 10
- **1 AFD profile** with 30 endpoints (3 per student: adaptix-redir-alice,
  mythic-redir-alice, sliver-redir-alice, × 10 students). Each endpoint
  fronts that one student's redirector; beacon binaries embed
  `*.azurefd.net` (no operator domain leak per the existing AFD architecture).
- **30 DNS CNAMEs** under the parent zone:
  `adaptix-redir-alice.enterprisesstudio.com → adaptix-redir-alice-AFD.azurefd.net`,
  etc.
- **10 student-magic-link URLs** printed by `./range creds`, one per
  student, each pre-authenticating that student's Guacamole user.

#### What `./range repair` does in shared mode

Same playbook as today, just with N×k hosts:
- `common` role baseline tooling: runs on all guac + all redirectors (today
  it skips kali / windows / linux01 — same skip rules apply)
- `redirector` role: 30 redirectors (3 per student × 10)
- `guacamole` role: 1 guac (re-runs register.py with all 10 students'
  connections registered)
- `adaptix` / `mythic` / `sliver` roles: 10 teamservers each
- `windows-base` role: 4 shared Windows targets (dc01, srv01, ws10, ws11) +
  1 shared analyst = 5 hosts (no per-student Windows because the lab is
  shared)
- `kali` role: 10 kalis (one per student) — full GUI + tools + wallpaper +
  bookmarks per the kali role's existing logic
- `adaptix_payload` / `mythic_payload` / `sliver_payload` / `brc4_payload`:
  one payload-build run per student's kali, against that student's
  teamservers

Wall time on a fresh deploy: ~30-45 min for terraform apply (most of which
is parallel-creating the 76 VMs); first `./range repair` is ~45-60 min
(longest pole is each kali doing its `kali-linux-default` apt install in
parallel).

Cost: ~3-5× a single redteam-lab deploy. The 6 shared targets are a fixed
cost; the 7 × 10 attacker VMs are the variable cost.

### Migration path from today

1. The first PR doesn't touch the single-deploy path. `envs/azure/` keeps
   working bit-for-bit identical.
2. Generator gains `render_env_dir(instance_idx)` that stamps out
   `inst-NN-azure/` from the same scenario YAML.
3. Range script gets the `--instance` flag.
4. Smoke-test with `--instance 2` (cheap), then `--instance 10`.

No breaking changes to the existing single-deploy flow at any step.

### Open questions / risks

| Question | Notes |
|---|---|
| Azure subscription resource-group quota | Default is 980 RGs per subscription. 10 instances = 10 RGs (+ DNS zone RG). Fine. 100 instances would be fine too. |
| Public IP quota | Default 1000 per subscription per region. 10 instances × ~5 PIPs (3 redirectors + guac + ?) = 50. Fine. |
| AFD profile limit | 25 profiles per subscription. Each instance has 1 shared profile (per-redirector ENDPOINTS, not per-redirector PROFILES). 10 profiles fits; 30 would not. |
| DNS zone record count | Azure DNS supports 10,000 record sets per zone. 10 instances × ~5 records = 50. Fine for years. |
| Cost guardrail | At 10× a single range, you want an Azure Cost Anomaly alert before spending $N/day. See §2.9. |
| State storage | Today: local `terraform.tfstate` per env dir. Multi-instance amplifies the "operator laptop is the source of truth" problem. Should consider Azure Blob remote state backend before this ships. |

---

## 1b. Pre-flight checklist for `shared` mode on redteam-lab

What's actually missing before `shared --count N` works end-to-end on the
existing `redteam-lab` scenario. Computed against the real scenario file
(`scenarios/redteam-lab.yaml`) and current code state.

### Major scope simplification: students use local IPs only

**Original plan**: each per-student redirector gets its own AFD endpoint
(`adaptix-redir-alice.azurefd.net`) + DNS CNAME, so student beacons go
out to AFD edge → back into Azure → student's redirector → teamserver.
That's the operator's path today (AFD beacon-binary OPSEC, hide custom
domain, etc.).

**Revised plan**: students' beacons callback to the per-student redirector's
**private IP** directly (e.g. `https://10.1.10.6:443`). The student's
kali, C2 teamserver, and redirector all live in the same per-student
attacker subnet inside the spoke VNet — beacons never leave the VNet,
no AFD, no DNS, no internet hairpin.

Why this is correct:
- This is a training lab, not a real engagement. Beacon-binary OPSEC
  doesn't matter when the "target" is dc01 sitting two subnets away.
- Students aren't simulating an internet-fronted callback path; they're
  learning C2 mechanics against an internal AD lab.
- The operator's BRC4 (per_student: false) still uses AFD if they want
  the full custom-domain setup for their own demos. AFD just isn't
  per-student anymore.

What this drops:
- **30 per-student AFD endpoints → 0.** (Only the operator's 1 BRC4
  redirector + the existing shared-infra AFD profile remain — well
  under any quota.)
- **30 per-student DNS CNAMEs → 0.**
- AFD quota concerns gone entirely.

This shifts work from §B3/§B4 NSG complexity (need to allow
attacker-<sid> → hub for AFD) — now per-student subnets only need
egress to the shared targets subnet. Simpler NSG rule set.

### Blocking gaps (must land before shared mode works at all)

| # | Gap | Files touched | Effort | Status |
|---|---|---|---|---|
| **B1** | **`per_student: bool` field in machine schema.** Added to (a) scenario YAML schema annotation, (b) `modules/azure/variables.tf` machine object type, (c) the generator's tfvars renderer. Default `true` (backward-compat with existing multi-student scenarios). | `scenarios/redteam-lab.yaml`, `modules/azure/variables.tf`, `generator/generate.py` | ½ day | **DONE** |
| **B2** | **Generator multi-instance expansion logic.** `expand_machines()` walks `machines[]`; per_student=true machines get N copies named `<sid>-<base>` (e.g. `lab01-kali`); per_student=false machines emit exactly once with student_id="", student_index=0. Validators added: (a) name_format must contain `{n}` in multi-student mode with per_student machines, (b) static_ip on per_student=false accepts full dotted IPv4 (not last-octet form), (c) BRC4 license check refined — only blocks count>1 when BRC4 is per_student=true. | `generator/generate.py` | ½ day | **DONE** |
| **B3** | **Per-student NIC subnet + listener-callback dispatch.** Three coupled changes landed: (a) added `hub_shared_lab` subnet (10.0.2.0/24) to `hub.tf` with its own NSG (inbound from all of 10.0.0.0/8, egress unrestricted) — this is where per_student=false target machines land in multi-student mode. (b) `vms.tf` `local.machine_subnet` / `machine_rg` / `machine_location` dispatch: if `m.student_id==""` AND `local.multi_student_shared` → route to `hub_shared_lab` + hub RG; else fall through to existing per-student spoke logic. `effective_static_ip` skips auto-IP computation for shared machines (would've collided with 10.0.1.X / hub_infra). (c) `listeners.tf` `azure_callback_for` adds a private-IP fallback: when AFD is disabled (or no redirector exists for that stack/student), resolves to the per-student teamserver's private IP via `effective_static_ip` lookup — beacons stay in-VNet, no `CHANGEME` placeholder. (d) Member-server / persona userdata `dc_ip` template var dispatches: shared mode → `cidrhost(var.hub_shared_lab_cidr, 10)` = 10.0.2.10; else → existing per-student convention. | `modules/azure/variables.tf`, `modules/azure/hub.tf`, `modules/azure/vms.tf`, `modules/azure/students.tf`, `modules/azure/listeners.tf`, `scenarios/student-redteam-lab.yaml` (dc01.static_ip → 10.0.2.10) | 1 day | **DONE** |
| **B4** | **NSG isolation between students.** Falls out for free from the existing per-student-VNet model: each student has their own `azurerm_virtual_network.student[sid]` at `10.<n>.0.0/22`, with NO peering between student spokes (only hub↔spoke). Alice's kali at 10.1.1.20 has no network path to bob's at 10.2.1.20 — they live in separate VNets that don't peer. The new `hub_shared_lab` NSG allows inbound from 10.0.0.0/8 so every student can reach the shared targets; egress restricted by the existing per-spoke NSGs (already present). | (no code; covered by existing architecture + B3 work) | 0 — covered | **DONE** |
| **B5** | **BRC4 is operator-only, not per-student.** Annotated in redteam-lab.yaml: `brc4` and `brc4-redir` both `per_student: false`. The generator's BRC4-license validator now correctly allows `count > 1` when BRC4 is per_student=false. | `scenarios/redteam-lab.yaml` | 0 — config | **DONE** |
| **B6** | **Operator SSH key shared across students.** Today the single `operator-id_ed25519` key lands in `authorized_keys` on every Linux VM (including each student's kali + C2 servers). In `shared` mode that means alice's kali has the SSH key that can reach bob's C2 boxes. Either: (a) per-student SSH keys (alice's kali has only the key that reaches alice's C2 boxes), OR (b) accept it (the threat model is "student is honest", not "student is malicious to peers"). **Recommendation: option (b) for the v1, document the trust assumption in the ROADMAP**. If you later want to harden, per-student keys are a follow-up (~1 day). | (documentation) | 0 — explicit non-decision | accepted v1 |
| **B7** | **`--student <SID>` flag implementation.** Wired into `./range repair`, `./range creds`, and the apply-time `--student` forward to the post-apply repair pass. Repair translates `--student lab01` to ansible `--limit '*-lab01-*'` (mutex with `--limit`, errors if both given). Creds threads `CREDS_STUDENT` env var into every per-student python heredoc — filters `student_credentials`, `student_logins`, `${stack}_connections`, `cdn_headers`, and the per-student VM IPs table down to just that student. Help text added to both subcommands. Heredoc delimiters quoted (`<<'USAGE'`) to disable backtick expansion in help text — pre-existing latent bug that surfaced when --help was first invoked. | `range` script | ½ day | **DONE** |

**Blocking subtotal: 0 — all 7 items resolved.** B1, B2, B3, B4, B5, B7 done; B6 accepted as v1 trust assumption.

Smoke-test status as of this writing:
- `./generator/generate.py scenarios/redteam-lab.yaml --provider azure` → renders cleanly; `terraform plan -refresh=false` → `Plan: 159 to add` (single-student).
- `./generator/generate.py scenarios/student-redteam-lab.yaml --provider azure --students 3` → renders 20 machines (5 shared + 15 per-student); `terraform plan -refresh=false` → `Plan: 280 to add` (multi-student, 3-student cohort).
- Both scenarios pass `terraform validate`.
- `./range repair --student lab02 --check` → prints `[--student] scoping repair to 'lab02' via ansible --limit '*-lab02-*'`, mutex with `--limit` enforced.
- `./range creds --student lab02` → header reads `RANGE CREDENTIALS (filtered to student 'lab02')`; per-student sections filtered.

Multi-student `shared` mode for `student-redteam-lab` is fully implemented and ready for a live test deploy.

### Computed resource counts (redteam-lab `shared` mode at N=10 students)

**VMs:**
| Class | Per | Quantity | vCPU/box | vCPU total |
|---|---|---|---|---|
| Shared targets (every student attacks these) | | | | |
| dc01 (windows-server-2022) | range | 1 | 4 | 4 |
| srv01 (windows-server-2019) | range | 1 | 2 | 2 |
| ws10, ws11 (windows-10/11) | range | 2 | 2 | 4 |
| analyst (windows-10) | range | 1 | 4 | 4 |
| linux01 (debian-12) | range | 1 | 2 | 2 |
| Per-student attacker kit | | | | |
| kali-<sid> | student | 10 | 4 | 40 |
| adaptix-<sid>, mythic-<sid>, sliver-<sid> | student | 30 | 4 | 120 |
| adaptix-redir-<sid>, mythic-redir-<sid>, sliver-redir-<sid> | student | 30 | 2 | 60 |
| Shared core (one of each, used by operator + students) | | | | |
| guac, ghostwriter, stepping-stones, redelk, elk | range | 5 | mixed | ~14 |
| Operator-only (not exposed to students) | | | | |
| brc4 + brc4-redir | range | 2 | mixed | ~6 |
| **Total** | | **~82 VMs** | | **~256 vCPUs** |

**⚠ Azure default vCPU quota per region is 10–350** (varies by subscription
tier — PAYG is 350, Free-tier is 10). **256 vCPUs likely EXCEEDS the default
quota** for any non-EA subscription. Quota increase request before `--count
10` apply: 2-5 business days for Azure to approve.

For N=3 students: ~50 VMs / ~120 vCPUs — fits in default PAYG quota.
For N=5 students: ~62 VMs / ~166 vCPUs — likely needs quota increase too.

**Public IPs:**
| Use | Count |
|---|---|
| Guac | 1 |
| Per-student redirectors | **0** (private IPs only — beacons stay in-VNet) |
| BRC4 redirector (operator's AFD-fronted; if enabled) | 1 |
| **Total** | **~2** |

Quota: 1000 default. Practically no public-IP usage at all in `shared` mode.

**AFD endpoints (after local-IP simplification):**
| Use | Count |
|---|---|
| Per-student redirectors | **0** (no AFD per student) |
| Operator's BRC4 redirector | 1 (if BRC4 license set) |
| Shared-infra AFD profile (existing) | 1 |
| **Total** | **~2** |

Way under quota. No quota concern.

**DNS records:** **0** new per-student records. Operator-side BRC4 keeps
its existing CNAME if AFD is enabled for that. Per-student C2 callback
paths use private IPs (e.g. `https://10.1.10.6:443`) — no DNS resolution
required at all.

**NSG rules:** 5 base + ~3 per attacker subnet + 2 on targets subnet
(allow inbound from each attacker subnet) = ~5 + 3×10 + 2×10 = **~55 rules
total**. Azure default per-NSG limit is 1,000. Fine.

**Random passwords generated:** ~6 per student (adaptix/mythic/brc4/sliver
+ operator + domain) × 10 = **60**. Tfvars.json gets ~150 KB (still readable).

### Cost estimate (rough — Azure Southeast Asia, Spot pricing, 8-hour-day)

Per single redteam-lab deploy today (baseline): **~$2k/month running 24/7**
(per the scenario YAML's note at line 7).

For `shared --count 10`:
- 6 shared targets + 5 shared core: 1× baseline (these are the bulk of the
  shared cost)
- 70 per-student attacker VMs: ~70/13 × (attacker portion of baseline)
- Estimated: **~$6-8k/month at 24/7**, or **~$2-3k/month with 8h/day pause**
  (Phase 3 of roadmap)

For `isolated --count 10`: **~$20k/month at 24/7** (10× baseline). Pause
mode brings it to ~$7k/month.

These are rough orders of magnitude — exact numbers depend on Spot eviction
rates, egress traffic, and SIG storage. Real cost-track via Azure Cost
Anomaly alert (Phase 3).

### Pre-apply quota checklist

Run before `./range up --mode shared --count 10`:

```bash
# vCPU quota — most likely to be the blocker
az vm list-usage --location southeastasia -o table | grep -iE "Family|vCPU|^Total"
# Look for: "Total Regional vCPUs" — must be ≥ 256

# Public IP quota — should be fine
az network list-usages --location southeastasia -o table | grep -i "Public IP"

# AFD endpoint count (per-profile) — verify SKU is Standard or Premium
az afd profile list -o table

# Subscription RG count — must be < 980 (each isolated deploy is 1 RG)
az group list --query "length(@)" -o tsv
```

If vCPU quota is short: open a quota-increase request in Azure portal
(Subscription → Usage + quotas → "Compute" → request) with target = ~300
vCPUs. Usually approved within 2-5 business days. Self-service approval
for sub-100-vCPU bumps.

### Scaling concerns (works at small N, watch at larger N)

| Concern | Threshold | Mitigation |
|---|---|---|
| Apply wall time grows linearly with N (parallel-creating ~7 VMs per student) | N=10: ~45 min apply; N=20: ~75 min | Acceptable. Azure ARM parallel-creates well. |
| First-`repair` kali apt install runs N times in parallel | N=10: each kali pulls ~2.5 GB; bandwidth into the spoke VNet bursts to ~5 Gbps for ~5 min | Cloud-init bandwidth is uncapped; this is fine but visible in Azure traffic metrics |
| Guacamole concurrent sessions | guacd handles 50-100 concurrent on a B-series. N=10 students × ~3 sessions each = 30. | Fine until N≈30 |
| Adaptix listener registration: 1 listener per CDN × per teamserver = 5 per student × N = 50 for N=10 | adaptix teamserver handles >>100 listeners | Fine |
| Per-student adaptix payload builds: 20 builds × N students = 200 builds total | Each kali builds its own student's matrix; no shared state | Fine; takes ~30 min wall time per kali in parallel |

### Operator UX gaps (still in §2 backlog, ranked here for shared mode relevance)

| Item | Why it matters for shared mode |
|---|---|
| §2.1 `./range health` | When 1 of 70 VMs is broken in a shared deploy, you want a one-shot validator that surfaces "which student's kit is unhealthy" |
| §2.8 `./range pause` / `resume` | At 24/7 cost for shared --count 10 ≈ $6-8k/mo. Pausing overnight saves ~60%. |
| §2.9 Cost guardrail | `./range up --mode shared --count 50` could spin up 350 VMs and bill thousands before anyone notices |
| Per-student magic-link printing in `./range creds` | Each student should get their own magic link (their Guac user, scoped to their connection group) — not the shared admin magic link |

### Smallest-step plan

Don't go N=10 first deploy. Sequence:

1. **Implement B1-B7** (blocking gaps, ~2-3 days)
2. **Smoke test with N=2** — apply, repair, verify alice and bob each see their own kit + shared targets, neither can see the other's kali
3. **N=5** — verify quotas, costs, wall-time at modest scale
4. **N=10** — first real cohort deploy, after quota increase approved

---

## 2. Backlog: operational gaps

Ranked by impact-per-effort, descending. Each item is a self-contained piece
of work; none block multi-instance.

### 2.1 `./range health` post-deploy validator — Medium priority

**Problem**: Today you deploy, then poke around to figure out what's broken.
The wallpaper-not-showing issue in this session would have been caught by an
automated checker.

**Proposal**: a new subcommand that walks every host in inventory and probes
a curated set of "this should be working" signals:

```
./range health [--instance <name> | --instance all] [--verbose]
```

Per-VM checks:
- SSH (or WinRM) reachable from guac
- Expected service ports open (3389 / 5985 / 8080 / 7443 etc. depending on
  role)
- Guacamole REST API returns 200 on `/api/tokens` with admin creds
- Guacamole magic-link generation succeeds
- Per-C2 listener health (e.g. adaptix `/login` returns 200, mythic
  `/agent/get_payload` returns expected JSON)
- HKLM Wallpaper policy set on Windows hosts (probe via WinRM
  `Get-ItemProperty`)
- Firefox bookmarks file present on kali
- LE cert validity (`openssl s_client | openssl x509 -enddate`)

Output: colored table, per-host pass/fail/skip, exit non-zero if any fail.

**Effort**: ~1 day. Reuses existing inventory rendering + the SSH-from-guac
path already in `./range repair`.

### 2.2 DoH/DNS listener generator wiring — Medium priority

**Problem**: Earlier this session we designed the DNS-C2-via-AFD architecture:
DoH at AFD edge with cover-page + custom-header gate, dnsdist sidecar
converting DoH→raw-DNS, beacon binary uses an `.azurefd.net` hostname (not
the operator's custom domain). The terraform/AFD/dnsdist/nginx sides are all
implemented. The missing piece is the generator (`generator/generate.py`)
threading the `dns_listeners` map + `terra_doh_*` hostvars from the scenario
YAML through to the ansible role group_vars.

**Proposal**: extend `generator/generate.py` to:
- Parse `dns_listeners:` block from scenario YAML
- Emit `var.advanced_c2.dns_listeners` into `terraform.tfvars.json`
- Emit `terra_doh_path` / `terra_doh_header_name` / `terra_doh_header_token`
  hostvars into the rendered inventory data dict so the redirector ansible
  role can pick them up

**Effort**: ~half day. Mostly mechanical given the design is done.

**When to do**: only when you have a scenario that actually needs DNS C2
listeners. Until then, the existing HTTPS listeners are sufficient.

### 2.3 Route warmer for VNet peering eviction — Medium priority

**Problem**: Azure VNet peering forwarding tables evict idle entries after
~30 minutes of no traffic. The next packet faces a ~30–90s blackout while the
table rebuilds. Most visible on the kali VM (RDP from guac → kali via spoke
peering): the first RDP click after lunch hangs for 90s, then works.

**Proposal**: a tiny daemon on guac that ICMP-pings every spoke host on a
2-minute interval. Cheap enough to be invisible. Keeps the peering forwarding
entries warm.

**Effort**: ~2 hours. Single systemd unit + a 10-line bash script.

### 2.4 WinRM HTTPS (5986) instead of HTTP (5985) — Low priority

**Problem**: Today's WinRM listener is plaintext HTTP + basic auth. Lab-tier
acceptable (the NSG only allows guac → Windows, no exposure to operator
laptop or internet), but every WinRM call traverses guac→VM as cleartext
basic-auth header. If guac is ever compromised, every Windows admin password
is harvestable.

**Proposal**: switch each Windows userdata's `winrm quickconfig` block to
generate a self-signed cert and bind WinRM to 5986/HTTPS. Update
`inventory.py` to set:

```python
vars_["ansible_port"]              = 5986
vars_["ansible_winrm_scheme"]      = "https"
vars_["ansible_winrm_transport"]   = "basic"   # still basic, but TLS-wrapped
vars_["ansible_winrm_server_cert_validation"] = "ignore"
```

**Effort**: ~3 hours. Mostly testing.

### 2.5 Snapshot-before-destroy — Low priority

**Problem**: `terraform destroy` is irreversible. Sometimes you destroy and
realize 5 minutes later you needed an artifact from a VM.

**Proposal**: pre-hook in `./range destroy` that snapshots every OS disk to
a `<rg>-snapshots/` resource group before terraform destroy fires. Snapshots
are cheap (~$0.05/GB/month) and disposable.

```bash
./range destroy --no-snapshot   # opt out
./range snapshots list          # see what you've got
./range snapshots delete inst-04-2026-05-15
```

**Effort**: ~half day. `az snapshot create` per disk + a small CLI.

### 2.6 Repair idempotency audit — Low priority

**Problem**: Some kali-role tasks (xrdp.ini Python rewrite, mythic cert NSS
import) MAY churn `changed=true` on every repair run even when there's
nothing to do. Pollutes the changed/ok ratio in PLAY RECAP and makes "did
anything actually change?" hard to answer.

**Proposal**: audit every task in every role for accurate `changed_when:`.
Where the underlying op is idempotent (most apt/copy/file tasks are), the
default works. Where it's a shell/script task, add an explicit `changed_when`
comparing before/after state.

**Effort**: ~half day across the whole ansible tree. Low value but reduces
noise.

### 2.7 Backup of Guacamole DB — Low priority

**Problem**: Operator-added connections / manual patches to the Guac DB are
lost on `terraform destroy`. The register.py manifest covers the canonical
connections, but anything an operator added manually post-deploy is gone.

**Proposal**: a 1-line cron job on guac that dumps the postgres DB to
`/var/backups/guac/postgres-YYYY-MM-DD.sql.gz` daily, with a 7-day rotation.
`./range backup pull` rsyncs them down to the operator's laptop.

**Effort**: ~1 hour.

### 2.8 Pause mode (deallocate at night) — DONE

**Problem**: VMs cost compute time whether running or not. A 10-instance
deploy left running overnight is paying for 10× the daytime cost.

**Shipped**:

```bash
./range pause       # deallocates every VM in this deployment
./range resume      # starts every paused VM back up
./range stop        # alias for pause
./range start       # alias for resume
./range deallocate  # alias for pause
```

Implementation:
- Walks `terraform show -json` for every
  `azurerm_{linux,windows}_virtual_machine` resource — picks up student VMs,
  shared targets, hub services (guac/elk/ghostwriter/...), operator BRC4.
- Per-VM `az vm deallocate --ids <id> --no-wait` (resp. `az vm start`).
  Idempotent: deallocating an already-stopped VM is a no-op, same for start.
- Sequential client-side submission + `--no-wait` lets Azure parallelize
  the actual stop/start server-side. ~30s of client time to submit N
  requests, ~2-3 min wall time before all VMs reach the target state.
- Failure tracking: if a per-VM `az` call fails, we count it but keep
  going — re-running `./range pause` is safe and retries only the ones
  that didn't go through.

Disks are ~$0.05/GB/month at rest, compute is the expensive line.
Pausing overnight + weekends drops compute spend by ~80% (4h/day × 5d/week
vs 24/7).

**Effort**: 2 hours (shipped). `--instance` flag for isolated-mode
fan-out can be added later when isolated mode itself ships.

### 2.10 Shared Guacamole (decoupled from per-range lifecycle) — Phase 2A DONE / Phase 2B pending

**Problem**: Every `./range apply` today spins up its own Guacamole VM. At
isolated-mode scale (10+ ranges) you pay 10× the Guac cost (~$1,100/mo)
for what could be one shared instance.

**Phase 2A — Standalone shared Guac module (DONE this session)**:
- `modules/shared-guac/` — standalone terraform module: own RG, own VNet
  (10.250.0.0/22, far from per-range CIDRs), own NSG, B4ms Guac VM with
  custom DNS hostname (e.g. `guac.cyberwarrange.com`)
- `envs/shared-guac-azure/` — own terraform state, lifecycle independent
  of any range deploy. `./range destroy` on a range doesn't touch this.
- `./range guac up|destroy|creds|status|plan|ssh|help` subcommands.
- Reuses the existing `modules/azure/userdata/guacamole.sh` template with
  optional features (wildcard cert / Key Vault / ssh key) set to empty
  defaults — bootstrap falls back to HTTP-01 LE cert against the single
  custom hostname.
- Cost: ~$110/mo at 24/7 B4ms, ~$25/mo with overnight + weekend pause.
  Same size as one current per-range Guac — break-even at 1 range,
  pure win at any N>1 (isolated mode).

**Phase 2B — Range apply integration (pending)**:
- Refactor `register.py` for multi-tenant namespaced registration —
  each range apply creates a new connection group
  (`/student-redteam-lab/cohort-2026-05-15/`) and registers its
  connections inside, instead of clobbering the whole DB.
- Auto-peer range VNet ↔ shared Guac VNet on apply (and remove
  peering on destroy) so Guac can reach range hosts via private IP.
- Super-admin auto-grant: `cwr-ian` user gets READ on every new
  cohort group automatically; per-student users get READ only on
  their own subgroup. Guac's UI hides groups the user can't see —
  no peer-discovery / leakage.
- Gate per-range Guac creation in `modules/azure/services.tf` behind
  a `var.services.guacamole.use_shared` flag (when true, range
  deploys skip per-range Guac creation and use the shared one).
- Migration path for existing deploys.

**Effort remaining**: ~3-4 days for Phase 2B. Phase 2A (the
foundation) is ~½ day done.

**How to use Phase 2A today** (manual workflow until Phase 2B):
1. `./range guac up` — stand up the shared Guac (~5-10 min).
2. `./range guac creds` — get the URL + admin password + magic link.
3. Range applies still create per-range Guacs (no behavior change yet).
4. Operator can MANUALLY add range connections to the shared Guac via the
   web UI (Settings → Connections → New) by referring to the range's
   `./range creds` output. Or ssh in and edit `/opt/guac/manifest.json`.

### 2.9 Cost guardrail — Low priority

**Problem**: A misconfigured `--mode isolated --count 100` could
accidentally spin up 100 ranges and bill thousands of dollars before anyone
notices.

**Proposal**:
- Azure Cost Anomaly alert wired into terraform at deploy time (creates the
  alert in the subscription scope on first apply, idempotent thereafter).
- `./range up` warns + requires `--yes` confirmation when the estimated
  daily cost crosses a configurable threshold (e.g. $50/day for a single
  deploy is fine, $500/day for `--instance 10` triggers the prompt).

**Effort**: ~half day for the warning prompt; the cost alert is mostly
boilerplate terraform.

---

## 3. Known risks on first apply

Informational — these aren't bugs to fix preemptively, just things to watch
for during the first apply of a fresh range so you recognize them quickly if
they surface.

| Symptom | Likely cause | Fix |
|---|---|---|
| `srv01 / ws10 / ws11 / analyst` shows up as standalone (no domain) | DC wasn't reachable when their userdata ran `Add-Computer` | `./range fix <vm-name>` re-runs the userdata once DC is up |
| Magic link from `./range creds` errors / 502 | LE cert not yet issued; guac still on self-signed | wait 2 min; re-run `./range creds`. Or `./range fix <guac-vm>` to retrigger the LE bootstrap |
| `adaptix_payload` role times out at 30 min, 0 built | Long-standing sliver-client `!#` echo marker bug, unrelated to other plays | expected; ignore — every other role still runs |
| First-boot kali apt install seems "stuck" for 30 min | normal — `kali-linux-default` is ~2.5 GB | tail `/var/log/cloud-init-output.log` on the kali VM; wait |
| First `./range repair` after fresh apply: `ansible.windows.win_file` unresolved | guac doesn't have the collection installed yet | range script's guac-bootstrap step installs `resolvelib==0.5.4` + the collections; re-run repair (the bootstrap is idempotent) |

---

## 4. Phasing recommendation

Suggested order of execution. Each phase is self-contained; you can stop
between phases without leaving anything broken.

### Phase 1 — Foundation for multi-instance (~2-3 days)
- Remote terraform state backend (Azure Blob) — prerequisite, today's local
  state model doesn't survive >1 operator
- Generator refactor: `render_env_dir(instance_idx)` accepts instance index
  + CIDR offsets
- `./range health` (§2.1) — needed to validate multi-instance deploys at scale

### Phase 2 — Multi-instance shipping (~1 day)
- `--mode {shared,isolated}` + `--count` flags wired into `./range up`
- `redteam-lab` scenario YAML grows the `per_student: true` flag on attacker-kit machines (kali, adaptix, mythic, sliver, redirectors)
- `--instance <name>` and `--instance all` selectors wired into all other subcommands
- CIDR allocation strategy implemented
- DNS namespacing
- `--instance all` parallel orchestration with `-j 4` throttle

### Phase 3 — Cost / lifecycle quality-of-life (~1 day)
- `./range pause` / `./range resume` (§2.8)
- `./range snapshots` (§2.5)
- Cost guardrail prompt (§2.9)

### Phase 4 — Hardening (no fixed order, pick as needed)
- Route warmer (§2.3)
- WinRM HTTPS (§2.4)
- Repair idempotency audit (§2.6)
- Guacamole DB backup (§2.7)
- DoH/DNS listener generator wiring (§2.2) — only when a scenario needs it

Total: ~5 focused days end-to-end for Phase 1–3, which is the
"multi-instance + quality-of-life" milestone. Phase 4 is opportunistic.

---

## Out of scope (intentionally)

- **Real SSO (OIDC/SAML) on Guacamole** — decided against this session in
  favor of the magic-link UX. Re-evaluate only if a multi-operator team
  with audit/compliance requirements adopts this.
- **Adaptix payload bulk-build automation refactor** — long-standing
  declined, deliberately untouched.
- **Kubernetes / container-per-student** — out of charter; terra-range is
  Azure-VM-centric by design.
- **Operator MFA on guac admin user** — magic link replaces password entry
  in the standard flow; if MFA is needed the better path is SSO (also out
  of scope).
