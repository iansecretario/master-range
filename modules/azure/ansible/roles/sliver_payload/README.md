# sliver_payload

Builds a fleet of [Sliver](https://github.com/BishopFox/sliver) implants
on Kali by driving `sliver-client --rc <file>`, and saves them to
`~/Desktop/payloads/sliver/`.

Authorized red-team / lab use only.

## When it runs

One of the final plays in `modules/azure/ansible/playbook.yml`,
after the `sliver` role (teamserver up, listeners registered) and the
`kali` role (sliver-client downloaded, operator.cfg imported).

On scenarios that don't deploy Sliver, the role skip-explains via
`meta: end_host`.

## How it works

Unlike Adaptix (REST) and Mythic (GraphQL), Sliver doesn't have a
build-an-implant HTTP endpoint. Instead, `sliver-client` accepts an
`--rc` flag that replays a script of commands. This role:

1. Discovers the Sliver teamserver by matching `terra_student_id` to
   the entry in `groups['sliver']` (falls back to first).
2. Verifies `sliver-client` and `operator.cfg` are in place on Kali
   (the `kali` role sets both up — fails fast otherwise).
3. Expands the matrix × listener-vias × transports cartesian product
   into one `generate ...` line per cell.
4. Writes the lines to `/tmp/sliver-build/build.rc`, runs
   `sliver-client --rc /tmp/sliver-build/build.rc`.
5. Walks each per-build save subdir, renames the produced binary into
   `<output_dir>/<via>_HTTPS-<agent>-<transport>-<arch>.<ext>`
   atomically (`copyfile` + `chmod` + `os.replace`).
6. Cleans up `/tmp/sliver-build/`.

## Filename format

`<listener_name>-<agent>-<transport>-<arch>.<ext>`

Examples from the defaults:

```
azure_HTTPS-sliver_session-http-amd64.exe
azure_HTTPS-sliver_session-http-amd64.bin            (shellcode)
azure_HTTPS-sliver_session-http-amd64.so             (linux shared)
azure_HTTPS-sliver_session-mtls-amd64.exe
azure_HTTPS-sliver_beacon-http-amd64.exe
cloudfront_HTTPS-sliver_session-http-amd64.exe
... etc
```

5 vias × 2 transports × (3 session builds + 2 beacon builds) = **50
binaries** by default. Trim by overriding `sliver_payload_matrix` and
`sliver_payload_transports`.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `sliver_payload_output_dir` | `/home/{{ ansible_user }}/Desktop/payloads/sliver` | Pre-created by kali role. |
| `sliver_payload_output_mode` | `0700` | |
| `sliver_payload_client_path` | `/home/{{ ansible_user }}/Desktop/Tools/sliver-client` | Pre-installed by kali role. |
| `sliver_payload_workdir` | `/tmp/sliver-build` | Reset on every run. |
| `sliver_payload_client_timeout_seconds` | `600` | Wall-clock budget for the entire `sliver-client --rc` invocation. |
| `sliver_payload_matrix` | see `defaults/main.yml` | Per-agent OS/format/arch list + session/beacon mode. |
| `sliver_payload_listener_vias` | `[{via,port}]` × 5 CDNs | Each `via` is a listener label; `port` is the matching listener port. |
| `sliver_payload_transports` | `[http, mtls]` | Override to `[http]` to halve the build count. |
| `sliver_payload_ext_for_format` | `{exe, shared, shellcode, service, elf}` | Filename extension per Sliver `--format`. |

## Notes

- Callback URLs default to the Sliver teamserver's PRIVATE IP. For
  AFD-fronted scenarios the operator can override the matrix to point
  at the redirector's public FQDN; this default produces in-VNet-only
  implants that work for lab testing.
- mTLS implants target the same port set (`8443-8447`) as the http
  ones, but go directly to the teamserver. The operator needs to
  register an mTLS listener on the teamserver if they want to actually
  receive callbacks (the existing `sliver` role registers HTTPS
  listeners only).
- Always rebuilds on every run — no skip-if-exists. Matches the
  `adaptix_payload` semantics.
- sliver-client occasionally fails a single `generate` line silently
  (e.g. unsupported format/OS combination); the post-walk surfaces
  that as `[!] <label>: no output` in the summary.
