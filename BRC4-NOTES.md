# Brute Ratel C4 — operator notes

## BRC4 is per-student, but `students.count` MUST be 1

BRC4 licensing constrains the range to **one teamserver activation per
license**, so c2-brc4 stays in the per-student `machines:` template
(matching Adaptix and Mythic) and the generator enforces
`students.count: 1` on any scenario that includes it. Multi-student
class scenarios cannot include BRC4.

If you generate against a multi-student YAML that has `c2-brc4` you'll
hit a clear error: *"c2-brc4 in `machines:` requires students.count: 1
(BRC4 license caps the range at one teamserver activation)."*

## Topology

```
Internet ──► CDN (AFD / CloudFront / workers.dev / Fastly / other)
                     │
              X-Api-<RandomName>: <UUID>      (per-student, per-CDN)
                     ▼
            redirector @ 10.<n>.1.10:443       (nginx, 5-way header→port map)
                     │
              proxy_pass to one of:
                     ▼
         BRC4 teamserver @ 10.<n>.1.9
              :9000  commander port (Kali @ 10.<n>.1.20 only, NSG-enforced)
              :8443  listener "azure_HTTPS"
              :8444  listener "cloudfront_HTTPS"
              :8445  listener "workers_HTTPS"
              :8446  listener "fastly_HTTPS"
              :8447  listener "other_HTTPS"
              :18080 commander binary serve (Kali only, 10-min window)
```

NSG enforcement (per-student attacker subnet, in `students.tf`):

| Source                    | Dest             | Ports        | Action |
| ------------------------- | ---------------- | ------------ | ------ |
| Kali `10.<n>.1.20`        | `.5/.7/.9`       | `9000`       | Allow  |
| Redirector `10.<n>.1.10`  | `10.<n>.1.9`     | `8443-8447`  | Allow  |
| Anything else             | `.5/.7/.9`       | `9000`, `8443-8447` | Deny |

## License prompts

`./range apply <scenario>` greps the YAML for `c2-brc4` and prompts:

```
License ID:       ...
Activation Key:   ...
License Email:    ...
Blob fallback URL [optional]: ...
```

Press **Enter** on License ID to skip — bootstrap exits cleanly, the
rest of the range still deploys. Credentials pass to Terraform as
`TF_VAR_brc4_*` env vars (sensitive in state).

## Pre-staging the BRC4 archive

There is **no online-download fallback**. Pre-stage your licensed BRC4
archive yourself:

1. Download the archive with your browser (logged into bruteratel.com).
2. Upload to an Azure Storage container with **private** access.
3. Generate a SAS URL with `read` permission and ≥ 30-day validity.
4. When `./range apply` prompts, paste it as **Blob fallback URL**.

The bootstrap downloads via the SAS URL, extracts to `/opt/bruteratel/`,
and expects `/opt/bruteratel/brute-ratel-linx64`. If the tarball
extracts to a differently-named top-level dir, the bootstrap symlinks
`/opt/bruteratel` to it.

## Activation

Activation is stdin-driven (matching `base42/teamserver_role_brc4`):

```
printf '%s\n%s\n' "$ACTIVATION_KEY" "$EMAIL" | /opt/bruteratel/brute-ratel-linx64
```

If your license version expects a different prompt order, edit
`modules/azure/userdata/c2-brc4.sh` Phase 3.

## Listener configuration via c2.profile

The bootstrap drops a fully-rendered `c2.profile` JSON at:

- `/opt/bruteratel/profiles/c2.profile`  (seed)
- `/opt/bruteratel/autosave.profile`     (what systemd loads)

Both contain the same content — five named HTTPS listeners with the
per-student per-CDN UUID embedded as `c2_authkeys`:

```
listeners:
  azure_HTTPS:       { port: "8443", ssl: true, c2_authkeys: ["<UUID>"], host: "<azure-callback>", ... }
  cloudfront_HTTPS:  { port: "8444", ssl: true, c2_authkeys: ["<UUID>"], host: "CHANGEME-cloudfront-<sid>", ... }
  workers_HTTPS:     { port: "8445", ssl: true, c2_authkeys: ["<UUID>"], host: "CHANGEME-workers-<sid>", ... }
  fastly_HTTPS:      { port: "8446", ssl: true, c2_authkeys: ["<UUID>"], host: "CHANGEME-fastly-<sid>", ... }
  other_HTTPS:       { port: "8447", ssl: true, c2_authkeys: ["<UUID>"], host: "CHANGEME-other-<sid>", ... }

c2_handler: "127.0.0.1:9000"   # commander
```

systemd:

```
ExecStart=/opt/bruteratel/brute-ratel-linx64 -ratel -r /opt/bruteratel/autosave.profile
```

Surface the per-CDN headers + UUIDs operators must inject at the CDN
origin via:

```
terraform output -json cdn_headers | jq '.<sid>.brc4'
```

The `azure` row's `host` is auto-populated to the AFD subdomain when
`advanced_c2.enabled = true`. The other four are placeholders
(`CHANGEME-cloudfront-<sid>` etc.) — edit `autosave.profile` after you
configure CloudFront / workers.dev / Fastly origins, then `systemctl
restart brc4`.

## Getting the GUI client onto Kali

The BRC4 archive ships both the teamserver and the operator client.
The bootstrap serves the client to Kali for **exactly one 10-minute
window** after activation:

1. Client binary copied to `/opt/bruteratel/commander.bin`.
2. `python3 -m http.server` runs on `:18080`, iptables-restricted to
   Kali (`10.<n>.1.20`) only.
3. After 10 minutes (`timeout 600`) the HTTP server exits, then
   `commander.bin` and `commander.sha256` are `shred`-deleted.

Pull from Kali during the window:

```bash
# from the Kali box (via Guacamole RDP or SSH):
curl -O http://10.<n>.1.9:18080/commander.bin
curl -O http://10.<n>.1.9:18080/commander.sha256
sha256sum -c commander.sha256
chmod +x commander.bin
./commander.bin
```

Connect: host `10.<n>.1.9`, port `9000`, password from
`terraform output -raw student_credentials | jq -r '.<sid>.brc4_teamserver_password'`.

If you miss the window: SSH to BRC4 via Guacamole and `scp` the
original binary out of the extracted tarball, or redeploy.

## RedELK integration

When `redelk` exists in the scenario's `shared_infrastructure`, the
BRC4 bootstrap also installs **Filebeat** and ships logs to the hub
RedELK at `10.0.1.40:5044`. Two input streams, two tag sets:

BRC4 writes its own logs to `/opt/bruteratel/logs/` after activation.
Per the upstream "Logging and Downloads" doc, four categories:

| Category | File(s)                         | Where | What it captures |
| -------- | ------------------------------- | ----- | ---------------- |
| Watchlist | `watchlist.log`                | base of `logs/` | Main server log; also what the operator sees in the Commander event panel |
| Upload/Download | `upload.log`, `download.log`, `sockets.log` | base of `logs/` | File-transfer events + sockets/pivot info |
| Badger   | `b-<id>.log` (e.g. `b-0.log`, `b-117.log`) | inside `MM-DD-YYYY/` | Per-badger session. Rotated at 00:00 every day — that's why a badger's terminal in Commander is reset at midnight |
| DeAuth/Web | `web.log`, `deauth.log` (when present) | inside `MM-DD-YYYY/` | The day's HTTP listener traffic + unauthenticated badger check-in attempts |

```
/opt/bruteratel/logs/
├── watchlist.log    ← Watchlist
├── download.log     ← Upload/Download
├── upload.log
├── sockets.log
└── MM-DD-YYYY/      ← one directory per active day
    ├── b-117.log    ← Badger (per-implant session)
    ├── b-118.log
    ├── ...
    ├── web.log      ← DeAuth/Web
    └── deauth.log   ← DeAuth/Web (when present)
```

Filebeat ships these as **two disjoint inputs** so each gets the right
fields and a dedicated dissect processor:

| Source                                 | `brc4_log_category` | tags                       | Extracted fields                          |
| -------------------------------------- | ------------------- | -------------------------- | ----------------------------------------- |
| `/opt/bruteratel/logs/*.log`           | `state`             | `c2`, `brc4`, `brc4-state` | `brc4_log_type` (download / sockets / upload / watchlist) |
| `/opt/bruteratel/logs/*/*.log`         | `session`           | `c2`, `brc4`, `brc4-session` | `brc4_log_date` (MM-DD-YYYY), `brc4_log_basename` (b-NNN \| web) |
| `/var/log/brc4-{bootstrap,activate,serve}.log` | n/a (`infralog: c2bootstrap`) | `c2`, `brc4`, `bootstrap`  | n/a — range-side deployment audit trail |

Both `c2log` inputs share `infra: c2`, `c2_program: brc4`, `c2_server:
brc4-<sid>`. Per-event `log.file.path` is preserved as well, so RedELK
Logstash can re-derive any of these on its own if you swap the
processor pipeline later.

### Multiline grouping

BRC4 logs each operator event as a timestamp-prefixed line followed by
zero-or-more continuation lines (output blocks, `[*]/[+]/[-]/[!]`
status markers, `+---+` separators). For RedELK to pair a command with
its response cleanly, Filebeat must group those lines as one event
rather than ship them individually.

The shipper config does this via:

```
multiline.pattern: '^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}'
multiline.negate: true
multiline.match: after
multiline.timeout: 5s
```

A line that doesn't start with `YYYY/MM/DD HH:MM:SS` is appended to
the previous event. A 5-second flush guarantees trailing output isn't
held forever if the next operator command is slow to arrive. Example:

```
2023/08/23 14:23:14 IST [input] admin => download VSCodeSetup-x64-1.62.3.exe
2023/08/23 14:23:14 IST [sent 136 bytes]
[*] Task-0 [Thread: 736]
[*] Downloading: VSCodeSetup-x64-1.62.3.exe
+----------------------------------------+
```

becomes two events:

| Event | message (truncated) |
| ----- | ------------------- |
| 1 | `[input] admin => download VSCodeSetup-x64-1.62.3.exe` |
| 2 | `[sent 136 bytes]\n[*] Task-0 [Thread: 736]\n[*] Downloading: ...\n+---+` |

RedELK Logstash then groks the first line of each `message` field for
operator/command/byte-count, and treats the rest as `output_body`.

### Sample RedELK Logstash filter — emits `input` + `output`

Per upstream's own guidance, a simple grok is all RedELK / ELK needs.
Drop this into `/etc/logstash/conf.d/60-c2-brc4.conf`:

```
filter {
  if "brc4-interactive" in [tags] {
    grok {
      match => {
        # `output` is optional so an `[input]` line that flushes via
        # multiline.timeout (with no continuation) doesn't tag
        # _grokparsefailure on every event.
        "message" => "(?m)\[input\] %{USERNAME:operator} => (?<input>[^\n]+)(?:\n(?<output>(?:.|\n)+))?$"
      }
    }
  }
}
```

Three fields land in Elastic per operator command:

| Field      | Example                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `input`    | `download VSCodeSetup-x64-1.62.3.exe`                                   |
| `output`   | everything after the first newline, verbatim — `[sent N bytes]` line, status markers, banner separators, multi-line response body. **Absent** when the event flushed without any continuation lines. |
| `operator` | `admin`                                                                 |

That's the whole pipeline. Anything else (status severity, bytes sent,
ISO timestamp, etc.) is one extra grok line per field — add only what
your dashboards actually need rather than baking everything in here.

The non-interactive event files (upload/download/sockets/web/deauth)
keep `infralog: c2log` but skip the `brc4-interactive` tag, so this
filter doesn't run on them — they arrive as plain timestamp-anchored
events that RedELK can grok separately if it cares.

### Worked examples — one Filebeat event per operator command

> Note: `output` carries actual LF (`0x0A`) newlines, not the literal
> two-character string `\n`. Kibana's document view renders them as
> real line breaks; the search-results table view collapses them for
> compactness, which is just a display choice.

#### `download VSCodeSetup-x64-1.62.3.exe`

`input`:

```
download VSCodeSetup-x64-1.62.3.exe
```

`output`:

```
2023/08/23 14:23:14 IST [sent 136 bytes]
[*] Task-0 [Thread: 736]
[*] Downloading: VSCodeSetup-x64-1.62.3.exe
+--------------------------------------------+
```

`operator` = `admin`.

#### `portscan 172.16.219.1 443 20-30 8443`

`input`:

```
portscan 172.16.219.1 443 20-30 8443
```

`output`:

```
2023/08/27 15:33:54 IST [sent 56 bytes]
[*] Task-1 [Thread: 2256]

[*] Scanning 172.16.219.1

[+] port 443/open
[+] port 20/closed
[+] port 21/closed
[+] port 22/open
[+] port 23/closed
[+] port 24/closed
[+] port 25/closed
[+] port 26/closed
[+] port 27/closed
[+] port 28/closed
[+] port 29/closed
[+] port 30/closed
[+] port 8443/open
[*] Scan complete
```

`operator` = `admin`.

#### `pivot_winrm ipconfig.exe /all`

`input`:

```
pivot_winrm ipconfig.exe /all
```

`output`:

```
2024/06/21 19:44:23 IST [sent 40 bytes]
[*] Task-0 [Thread: 5540]
[+] WinRM Output:

Windows IP Configuration

   Host Name . . . . . . . . . . . . : vortexdc
   Primary Dns Suffix  . . . . . . . : darkvortex.corp
   Node Type . . . . . . . . . . . . : Hybrid
   IP Routing Enabled. . . . . . . . : No
   WINS Proxy Enabled. . . . . . . . : No
   DNS Suffix Search List. . . . . . : darkvortex.corp

Ethernet adapter Ethernet0:

   Connection-specific DNS Suffix  . :
   Description . . . . . . . . . . . : Intel(R) 82574L Gigabit Network Connection
   Physical Address. . . . . . . . . : 00-0C-29-73-DC-A9
   DHCP Enabled. . . . . . . . . . . : No
   ...
```

`operator` = `admin`.

Each is one Filebeat event → one Elastic doc, with newlines preserved
end-to-end so Kibana renders the response as the operator originally
saw it in Commander.

Note: `/opt/bruteratel/logs/` is created and populated by BRC4 itself
**after activation completes** — the bootstrap doesn't touch it.
Filebeat's harvester picks up files as they appear, so the first
events flow only after the operator runs the commander client and
badgers start checking in.

The shipper is **plain-text** (`output.logstash` with `ssl.enabled:
false`). RedELK's `initial-setup.sh` generates real TLS certs that
should replace the plain config post-deploy:

```bash
# on the RedELK box, after running initial-setup.sh:
scp /opt/redelk/certs/elkserver.crt ranger@10.<n>.1.9:/etc/filebeat/
ssh ranger@10.<n>.1.9 'sudo sed -i "s|ssl.enabled: false|ssl.enabled: true\n  ssl.certificate_authorities: [\"/etc/filebeat/elkserver.crt\"]|" /etc/filebeat/filebeat.yml && sudo systemctl restart filebeat'
```

Skip the Filebeat block entirely by leaving `redelk` out of
`shared_infrastructure:` — the userdata's `if [ -n "${redelk_ip}" ]`
guard short-circuits.

## CDN origin header configuration

The redirector accepts traffic only with the matching
`X-Api-<Random>: <UUID>` header. Look up via:

```
terraform output -json cdn_headers | jq '.<sid>.brc4'
```

```json
{
  "azure":      { "name": "X-Api-Token",   "value": "<UUID>", "port": 8443 },
  "cloudfront": { "name": "X-Api-Auth",    "value": "<UUID>", "port": 8444 },
  "workers":    { "name": "X-Api-Cdn",     "value": "<UUID>", "port": 8445 },
  "fastly":     { "name": "X-Api-Edge",    "value": "<UUID>", "port": 8446 },
  "other":      { "name": "X-Api-Profile", "value": "<UUID>", "port": 8447 }
}
```

| CDN              | Where to inject                                           |
| ---------------- | --------------------------------------------------------- |
| Azure Front Door | Auto-injected by Terraform (rule engine)                  |
| CloudFront       | Origin → Custom Headers → `X-Api-<Random>: <UUID>`        |
| Cloudflare workers.dev | Worker fetch options `headers: { 'X-Api-...': '<UUID>' }` |
| Fastly           | Origin → Override host headers → `X-Api-<Random>: <UUID>` |
| other            | Whatever you wire in front of the redirector              |

## Limitations / known gaps

- **No DNS C2 listener** — listener pool is HTTPS-only.
- **Wildcard cert via certbot** — not implemented. AFD uses managed
  certs per subdomain; CloudFront/Fastly handle TLS themselves.
- **Non-Azure CDN callback hosts are placeholders.** Edit
  `autosave.profile` post-deploy and `systemctl restart brc4`.
- **Filebeat → RedELK uses plain text** — replace with TLS post-deploy
  using certs from RedELK's `initial-setup.sh`.

## Troubleshooting

**"c2-brc4 in `machines:` requires students.count: 1"** — your scenario
has both BRC4 and multi-student. License doesn't allow it; pick one.

**"Blob download failed (network? expired SAS?)"** — SAS URL
unreachable, expired, or you forgot to authorize anonymous read.

**"`/opt/bruteratel/brute-ratel-linx64` not found after extract"** —
archive's binary name changed. Inspect `/opt/bruteratel/` and adjust
the path check in `userdata/c2-brc4.sh`.

**"Activation didn't complete"** — check `/var/log/brc4-activate.log`.
Activate manually: SSH to BRC4 via Guacamole, run
`/opt/bruteratel/brute-ratel-linx64`, follow prompts.

**"Teamserver not listening on :9000"** — check `/var/log/brc4.log`.
Most common: activation didn't take. `systemctl restart brc4` after
manual activation.

**"Commander binary serve window already closed"** — you missed the
10-minute window. SSH to BRC4 and `scp` the original binary from the
extracted tarball.

**"Beacon connects to redirector but BRC4 returns 401/no response"** —
listener `c2_authkeys` mismatch. Compare `terraform output cdn_headers`
to what payload generation embedded.

**"Filebeat keeps reconnecting to RedELK"** — RedELK's Logstash isn't
up yet (operator hasn't run `initial-setup.sh` and `docker compose up
-d` on the RedELK box). That's expected; Filebeat will catch up once
RedELK is online.
