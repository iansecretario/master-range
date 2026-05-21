# mythic_payload

Builds [Mythic](https://github.com/its-a-feature/Mythic) payloads via
the REST API on Kali and saves them to `~/Desktop/payloads/mythic/`.

Authorized red-team / lab use only.

## When it runs

One of the final plays in `modules/azure/ansible/playbook.yml`,
after the `mythic` role (teamserver up, httpx profile installed with
5-instance config) and the `kali` role (output dir created).

On scenarios that don't deploy Mythic, the role skip-explains via
`meta: end_host`.

## How it works

1. Discovers the Mythic teamserver by matching `terra_student_id`
   against `groups['mythic']`. Falls back to first.
2. Slurps `/opt/mythic-env` from the teamserver via `delegate_to`,
   extracts `MYTHIC_ADMIN_USER` + `MYTHIC_ADMIN_PASSWORD`.
3. POSTs `/auth` to get a JWT access token (12 × 5s retry budget for
   cold-boot teamservers).
4. For each agent × build × listener via:
   - POST `/api/v1.4/payloads/create` with `{payload_type, selected_os,
     filename, c2_profiles: [httpx], build_parameters}`.
   - Poll `GET /api/v1.4/payloads/<uuid>` until `build_phase` →
     `success` or `error` (default budget: 600s).
   - Download via `GET /direct/download/<uuid>`.
   - Atomic write to
     `<output_dir>/<via>_HTTPS-<agent>-<arch>.<ext>`.

## Filename format

`<listener_name>-<agent>-<arch>.<ext>` (same as the other three
frameworks).

Default matrix (5 vias × 7 agent/format combos = 35 binaries):

```
azure_HTTPS-apollo-x64.exe
azure_HTTPS-apollo-x64.dll
azure_HTTPS-apollo-x64.bin     (raw shellcode)
azure_HTTPS-poseidon-x64.elf
azure_HTTPS-poseidon-x64.bin   (macOS mach-o)
azure_HTTPS-athena-x64.exe
azure_HTTPS-athena-x64.elf
cloudfront_HTTPS-apollo-x64.exe
...
```

## Variables

| Variable | Default | Notes |
|---|---|---|
| `mythic_payload_output_dir` | `/home/{{ ansible_user }}/Desktop/payloads/mythic` | |
| `mythic_payload_output_mode` | `0700` | |
| `mythic_payload_server_port` | `7443` | Set by `c2-mythic.sh`. |
| `mythic_payload_validate_certs` | `false` | Self-signed teamserver cert. |
| `mythic_payload_c2_profile` | `httpx` | The 5-instance profile. |
| `mythic_payload_matrix` | apollo + poseidon + athena | See `defaults/main.yml`. |
| `mythic_payload_listener_vias` | `[{via,port}]` × 5 CDNs | |
| `mythic_payload_login_retries` | `12` | |
| `mythic_payload_login_delay_seconds` | `5` | |
| `mythic_payload_build_poll_seconds` | `5` | Per-payload poll interval. |
| `mythic_payload_build_poll_max_seconds` | `600` | Hard timeout per payload. |

## Notes

- The Mythic REST API surface changes between major releases. This
  role targets the v1.4 schema as of mythic-cli main. If your deploy
  uses a newer version with different field names, override the
  matrix `build_parameters` or open the tasks/main.yml `create_payload`
  function and adjust the body shape.
- `httpx` C2-profile parameters: we send the minimum needed (`callback_host`,
  `callback_port`, `callback_interval`, `callback_jitter`, `AESPSK`,
  `raw_c2_config`). For raw_c2_config we synthesise a minimal valid TOML
  stub keyed on the per-via listener port. Real-world tradecraft would
  customise this further (User-Agent, headers, jitter pattern, etc.).
- Each payload build runs a Docker container on the teamserver (the
  agent's `build_python.py`). Cold-cache compile time is 30-180s per
  build for apollo/athena (.NET Roslyn); poseidon is faster (~30s).
- Always rebuilds — no skip-if-exists.
- Per-build try/except surfaces individual failures without aborting
  the remaining payloads.
