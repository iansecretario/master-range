# Personas

A **persona** is a named, self-contained bash script that turns a plain
`linux-target` into a themed, intentionally-vulnerable CTF box. Personas
are referenced by name from a scenario YAML.

## Model

```yaml
machines:
  - { name: starky, role: linux-target, os: debian-12, size: medium, persona: starky }
  - { name: sentry, role: linux-target, os: ubuntu-22, size: medium, persona: sentry }
```

What happens at deploy time:

1. The generator validates that `personas/<name>.sh` exists and embeds
   its content (base64) into the machine's tfvars entry.
2. Terraform renders a different cloud-init payload for the machine —
   `linux-persona.sh` instead of `linux-target.sh`.
3. On first boot, cloud-init does the standard linux-target setup
   (user, SSH, hostname), then writes the persona script to disk and
   executes it as root.
4. After the persona finishes, cloud-init runs an auto-clean step:

   - removes `/tmp/persona.sh`
   - truncates `/var/log/cloud-init.log` and `/var/log/cloud-init-output.log`
     (these would otherwise contain the full rendered persona script)
   - removes `/var/lib/cloud/instance/scripts/runcmd` (the original
     runcmd, which contains the persona invocation)
   - rotates and vacuums the systemd journal

The cleanup is **deliberately narrow**. It only touches build artifacts.
Anything the persona wrote — fake `.bash_history` files, sensitive
`/var/backups/...` content, planted flags, exposed `/etc/shadow` entries,
seeded `/var/log/auth.log` lines — is preserved. That's the point: the
persona is the lab content; the cleanup hides only how the lab was built.

## Authoring a persona

A persona is just a bash script that:

- Uses `#!/usr/bin/env bash`
- Runs as root (cloud-init guarantees this)
- Does not require interactive input
- Returns 0 on success (cloud-init treats non-zero as a failure but
  doesn't roll anything back)
- May safely assume the box has internet egress (build phase runs
  before `lockdown=true` is applied)

You can do anything in a persona that you'd do in a one-shot setup
script: install packages, create users, write fake history files,
configure services, plant flags. The bundled `starky.sh` is a full
example covering web apps, MariaDB, NFS, sudo misconfigurations,
SUID privesc paths, Docker socket exposure, and CTF flags.

## Built-in personas

| Name      | Theme                                       | Size suggestion |
| --------- | ------------------------------------------- | --------------- |
| `starky`  | Stark Industries — full corporate compromise chain (15 flags, 2225 pts) | medium |
| `sentry`  | Template: security-monitoring box that's itself misconfigured           | medium |
| `warrrix` | Template: hardened-looking Linux box with deep privesc paths             | large  |

`sentry` and `warrrix` are skeletons — banner, package install, user
creation, and a flag-planting stub. Fill them with whatever vulnerable
content fits your training narrative.

## Adding a new persona

1. Drop a new file in this directory: `personas/myname.sh`
2. Reference it from a scenario:
   ```yaml
   machines:
     - { name: my-box, role: linux-target, os: debian-12, persona: myname }
   ```
3. `./range apply <scenario>` — that's it.

The generator will fail fast if the persona file doesn't exist, isn't
readable, or is empty.

## Operational notes

- **Personas are per-student-cloned.** If `students.count: 20` and
  the template includes a `persona: starky` machine, you get 20
  independent Stark boxes — one per student VNet, isolated from each
  other. Flags can therefore be identical across students; they can't
  see each other's boxes.
- **Persona scripts run after standard cloud-init**, so the
  `default_credentials.linux_user` already exists before the persona
  starts. The persona can choose to remove or shadow that user as
  part of its setup (Stark does this by adding several themed users
  and granting one of them passwordless sudo).
- **Cleanup is best-effort.** A determined operator with root on the
  box could still find traces in dpkg logs, package mtimes, and
  Azure VM creation timestamps. For deeper anti-forensics, extend
  the cleanup phase in `modules/azure/userdata/linux-persona.sh`.
- **Persona scripts only apply to `linux-target` role.** Windows
  personas would require a parallel `.ps1` mechanism through CSE.
