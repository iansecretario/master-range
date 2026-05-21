# adaptix_payload

Generates a fleet of [AdaptixC2](https://github.com/Adaptix-Framework/AdaptixC2)
agent payloads via the teamserver's REST API and drops them on the
target Kali host at `~/Desktop/payloads/adaptix/`.

Authorized red-team / lab use only.

## When it runs

This role is the **last play in `modules/azure/ansible/playbook.yml`**.
It executes only after:

1. The `adaptix` role has finished — teamserver built, listeners registered,
   `/endpoint/login` responding.
2. The `kali` role has finished — `AdaptixClient` Qt6 build async-completed,
   `~/Desktop/payloads/adaptix/` created, `~/.adaptix/storage-v1.db`
   seeded with the connect profile.

That ordering guarantees both ends of the toolchain are at steady state
before payloads start landing on disk.

On scenarios that don't deploy Adaptix at all (e.g. `scenarios/vulhub.yaml`),
the role skip-explains and ends the play for that host with `meta: end_host`
instead of failing.

## What it does

1. **Find the right teamserver.** Picks the host in `groups['adaptix']`
   whose `terra_student_id` matches this Kali's. Falls back to the first
   adaptix host so single-tenant ranges still work. No static IPs.
2. **Read the operator password.** Slurps `/opt/adaptix/profile.yaml`
   from the teamserver via `delegate_to` and extracts
   `Teamserver.operators.ranger` (falling back to `Teamserver.password`).
   Single source of truth — no vault, no inventory secret.
3. **Login + discover listeners + build the matrix in ONE process.** The
   role's heavy lifting is a single Python `shell:` task that:
   - retries `/login` until the (potentially still-cold-booting)
     teamserver responds,
   - calls `GET /listener/list` to discover live listener names,
   - expands `adaptix_payload_matrix × adaptix_payload_listener_vias`,
   - POSTs `/agent/generate` per entry,
   - base64-decodes the `b64(filename):b64(content)` response,
   - writes to `<output_dir>/<listener>-<agent>-<arch>.<ext>` atomically
     (tmp file + `os.replace`).

Doing everything in one Python process matters because AdaptixServer's
JWT access_token has a sub-minute TTL — an Ansible `loop:` over 25 `uri:`
calls would blow the token mid-loop. Same reason `roles/adaptix` uses a
single atomic Python task for listener reconcile.

## Filename format

`<listener_name>-<agent>-<arch>.<ext>`

Examples (defaults expand to 25 binaries):

```
azure_HTTPS-beacon-x64.exe
azure_HTTPS-beacon-x64.dll
azure_HTTPS-beacon-x64.bin            (shellcode)
azure_HTTPS-beacon-x64.svc.exe        (service-exe)
azure_HTTPS-gopher-x64.elf
cloudfront_HTTPS-beacon-x64.exe
cloudfront_HTTPS-beacon-x64.dll
...
other_HTTPS-gopher-x64.elf
```

The listener name is the first segment so an `ls` of `~/Desktop/payloads/adaptix/`
sorts by CDN — the most useful grouping when picking which front to
deploy through.

`<ext>` is controlled by `adaptix_payload_ext_for_format`:

| format        | ext         |
|---------------|-------------|
| `exe`         | `.exe`      |
| `dll`         | `.dll`      |
| `shellcode`   | `.bin`      |
| `service-exe` | `.svc.exe`  |
| `elf`         | `.elf`      |

## Variables

All overrides go in `group_vars/all.yml` or per-host vars.

| Variable | Default | Notes |
|---|---|---|
| `adaptix_payload_output_dir` | `/home/{{ ansible_user }}/Desktop/payloads/adaptix` | Created if missing. Owned by `ansible_user`. |
| `adaptix_payload_output_mode` | `0700` | Permissions on each written binary. |
| `adaptix_payload_operator_username` | `ranger` | Matches `c2-server.sh:69`'s `${operator_user}`. |
| `adaptix_payload_matrix` | beacon×{exe,dll,shellcode,service-exe} + gopher×{elf} | See below. |
| `adaptix_payload_listener_vias` | `[azure, cloudfront, workers, fastly, other]` | Resolved by prefix-match against live `GET /listener/list`. |
| `adaptix_payload_ext_for_format` | see table above | Override to add formats. |
| `adaptix_payload_login_retries` | `12` | At `delay_seconds` each = 60s default backoff window. |
| `adaptix_payload_login_delay_seconds` | `5` | |
| `adaptix_payload_build_timeout_seconds` | `120` | Per-build HTTP timeout. mingw cross-compile is slow on a cold cache. |

### `adaptix_payload_matrix` shape

```yaml
adaptix_payload_matrix:
  <agent_registration_name>:
    arch: x64
    formats: [exe, dll, shellcode, service-exe]
    # Extra keys merged into every entry's `config` dict for this agent.
    # Use for agent-specific build options beyond {os, arch, format}.
    config_extra: {}
```

The role iterates `agents × formats × listener_vias` and produces one
payload per cell. `os` is auto-set per-format (`elf` → linux, everything
else → windows) — override per-agent via `config_extra: { os: ... }`.

## Config keys are agent-specific

The `config` field sent to `/agent/generate` is **opaque to the teamserver**
— it's handed straight to the agent extender's `PluginAgent.BuildPayload`.
This is confirmed by the [agent-plugin doc](https://adaptix-framework.gitbook.io/adaptix-framework/development/extenders/agent-plugin.md)
and the [Web API doc](https://adaptix-framework.gitbook.io/adaptix-framework/development/teamserver-interface/web-api).

The actual keys come from each agent extender's AxScript `GenerateUI()`
function. The role ships **placeholder defaults** matching the shape we
believe the stock `beacon_agent` accepts: `{os, arch, format}`. If your
deploy is running a newer Adaptix and these stop working:

1. SSH to the teamserver and read the extender source directly:
   ```bash
   ls /opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_agent/
   cat /opt/adaptix/AdaptixC2/AdaptixServer/extenders/beacon_agent/config.tpl
   # The AxScript GenerateUI() body defines the GUI dialog fields, which
   # is the canonical key list.
   ```
2. Update the keys in `adaptix_payload_matrix.<agent>.config_extra` to
   match (or replace the placeholder `formats:` list entirely if the
   extender renamed them).

`gopher_agent` config lives under
`AdaptixC2/AdaptixServer/extenders/gopher_agent/` with the same layout.

The role validates the agent registration name implicitly: a wrong
agent name comes back from `/agent/generate` as `ok: false` with a
clear `message`, and the role's per-build `[!]` line surfaces it.

## Failure tolerance

Each build is try/except'd inside the Python script. One failed
`/agent/generate` doesn't abort the other 24. The task succeeds if at
least one binary was built; fails clean with a non-zero exit if 0/25
succeeded. Per-build `[!]` lines + a final `[+] N built, M failed`
summary land in the Ansible run output.

## Running it standalone

The role is invoked automatically as the last step of `./range repair`.
For a payload-only refresh:

```bash
cd modules/azure/ansible
TERRA_ENV=/abs/path/to/envs/azure ansible-playbook playbook.yml --tags adaptix_payload
# or limit to a single Kali:
TERRA_ENV=/abs/path/to/envs/azure ansible-playbook playbook.yml --tags adaptix_payload --limit kali-xrdp
```

## Notes

- Always rebuilds on every run — no skip-if-exists logic. Repair is
  operator-initiated and infrequent, and unconditional rebuilds keep
  binaries in sync with the current listener `callback_addresses`
  (e.g. after the operator wires up a CDN front and re-runs).
- Atomic writes: tmp file in the same directory + `os.replace`, so a
  mid-decode crash leaves the previous binary intact.
- Credentials and the JWT access_token are kept in process memory only;
  every Ansible task that touches them is `no_log: true`.
