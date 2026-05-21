# brc4_payload

**Stub role.** Brute Ratel C4 has no headless build API; badgers are
built via the Windows Brute Ratel GUI client only. This role exists
to keep the playbook structure uniform with the other three C2
frameworks (adaptix / sliver / mythic) and to drop a manual-procedure
README onto Kali.

## What it does

1. Skip + `meta: end_host` when `groups['brc4']` is empty (most
   scenarios; BRC4 is license-gated and only included when explicitly
   configured).
2. Ensure `~/Desktop/payloads/brc4/` exists.
3. Write `~/Desktop/payloads/brc4/README.txt` with the GUI build
   procedure, listener/CDN reference, and the suggested filename
   convention (`<listener_name>-badger-x64.exe`) so manually-built
   badgers sort the same as the other frameworks' auto-built payloads.

## When BRC4 ever ships a headless build API

Replace `tasks/main.yml` with a real build implementation following
the same pattern as `adaptix_payload` / `sliver_payload` /
`mythic_payload`. The role name, playbook wiring, tags, and output
directory stay the same — the operator-facing contract doesn't
change.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `brc4_payload_output_dir` | `/home/{{ ansible_user }}/Desktop/payloads/brc4` | Already created by the kali role; this role is defensive. |
