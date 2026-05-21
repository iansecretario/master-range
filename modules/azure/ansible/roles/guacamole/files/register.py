#!/usr/bin/env python3
"""
register.py — consumes /opt/guac/manifest.json and calls the
Guacamole REST API to create:
  - one connection group per student
  - one connection per machine, prefilled with creds
  - one user per student, granted READ on only their group
Idempotent: re-running won't create duplicates (looks up by name).
"""
import json, sys, time, urllib.parse, urllib.request, urllib.error

BASE = "http://localhost:8080/guacamole"

def req(method, path, token=None, payload=None):
    url = f"{BASE}{path}"
    if token:
        url += ("&" if "?" in url else "?") + "token=" + token
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            body = resp.read().decode() or "{}"
            return resp.status, json.loads(body) if body.strip().startswith(("{", "[")) else body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def login(user, pw, max_tries=10):
    # form-encoded
    url = f"{BASE}/api/tokens"
    data = urllib.parse.urlencode({"username": user, "password": pw}).encode()
    for _ in range(max_tries):
        try:
            r = urllib.request.Request(url, data=data, method="POST")
            with urllib.request.urlopen(r, timeout=10) as resp:
                return json.loads(resp.read().decode())["authToken"]
        except (urllib.error.URLError, urllib.error.HTTPError):
            time.sleep(5)
    return None

def main():
    m = json.load(open("/opt/guac/manifest.json"))
    admin_user = m["admin"]["username"]
    admin_pw   = m["admin"]["password"]

    # Wait for the API to be reachable at all (long retry).
    for _ in range(60):
        try:
            urllib.request.urlopen(f"{BASE}/", timeout=5).read()
            break
        except Exception:
            time.sleep(5)

    # Try configured admin password first (re-runs are idempotent).
    token = login(admin_user, admin_pw, max_tries=3)
    if token is None:
        # First run path: rotate from default guacadmin/guacadmin.
        token = login("guacadmin", "guacadmin", max_tries=12)
        if token is None:
            raise SystemExit("guacamole api never came up with default creds")
        # Rotate the default password to the configured one.
        req("PUT",
            "/api/session/data/postgresql/users/guacadmin/password",
            token=token,
            payload={"oldPassword": "guacadmin",
                     "newPassword": admin_pw})
        token = login(admin_user, admin_pw, max_tries=12)
        if token is None:
            raise SystemExit("guacadmin password rotation failed")

    # Create per-student connection groups.
    # Map student_id -> group identifier returned by API.
    group_ids = {}
    # Existing groups
    status, existing = req("GET", "/api/session/data/postgresql/connectionGroups",
                           token=token)
    name_to_id = {v["name"]: k for k, v in (existing or {}).items()} \
                 if isinstance(existing, dict) else {}

    students = sorted({c["student_id"] for c in m["connections"] if c["student_id"]})
    if not students:
        students = [""]   # single-student mode
    for sid in students:
        gname = sid if sid else "range"
        if gname in name_to_id:
            group_ids[sid] = name_to_id[gname]
            continue
        status, body = req("POST", "/api/session/data/postgresql/connectionGroups",
                           token=token,
                           payload={
                             "parentIdentifier": "ROOT",
                             "name": gname,
                             "type": "ORGANIZATIONAL",
                             "attributes": {}
                           })
        if isinstance(body, dict) and "identifier" in body:
            group_ids[sid] = body["identifier"]

    # Create connections.
    status, existing_conns = req("GET",
                                 "/api/session/data/postgresql/connections",
                                 token=token)
    conn_name_to_id = {v["name"]: k for k, v in (existing_conns or {}).items()} \
                      if isinstance(existing_conns, dict) else {}
    created_conns = []
    for c in m["connections"]:
        params = {
          "hostname": c["hostname"],
          "port":     str(c["port"]),
          "username": c["username"],
          "password": c["password"],
        }
        # VNC connections need ONLY hostname/port/password — no
        # username, no security-mode params. Guacamole's VNC plugin
        # accepts username (harmless) but some VNC servers reject it.
        # TigerVNC ignores it cleanly so we leave the field in.
        # The password matches the VNC password we set in the kali
        # ansible role (vncpasswd -f → ~/.config/tigervnc/passwd).
        if c["protocol"] == "vnc":
            params["color-depth"]    = "24"
            params["autoretry"]      = "3"
            # force-lossless: ship updates as PNG, not JPEG.
            # JPEG compression smears anti-aliased glyph edges,
            # making terminal/editor text look "blurry" at any
            # framebuffer size that isn't exactly the operator's
            # viewport. PNG is lossless — text edges stay crisp
            # at the cost of ~30-40% more bytes per dirty region.
            # Worth it for a Kali desktop where 80% of pixel
            # changes are text-heavy.
            params["force-lossless"] = "true"
            # cursor=remote: render the server's actual cursor
            # rather than overlaying a generic client cursor.
            # XFCE's cursor has subpixel hinting that survives
            # network transit cleanly; the default local cursor
            # in Guacamole sometimes desyncs from the framebuffer
            # during quick window switches.
            params["cursor"]         = "remote"
            # Per-connection overrides — services.tf can pass
            # additional VNC params (e.g. width/height hints)
            # through manifest entry's optional `_extra_vnc_params`
            # subobject without forking this register.py.
            for _k, _v in (c.get("_extra_vnc_params") or {}).items():
                params[_k] = _v
        # Optional SFTP file-transfer overlay. Guacamole's VNC
        # protocol has no native file transfer; this enables a
        # sidebar that uploads/downloads via SSH to the same host
        # (or any other host the operator points to). Triggered
        # by an `sftp` subobject on the manifest connection entry —
        # see services.tf where Kali entries get one filled in.
        # Works for vnc + ssh + rdp protocols alike.
        if c.get("sftp") and c["sftp"].get("enabled"):
            s = c["sftp"]
            params["enable-sftp"]         = "true"
            params["sftp-hostname"]       = s.get("hostname", c["hostname"])
            params["sftp-port"]           = str(s.get("port", 22))
            params["sftp-username"]       = s.get("username", "")
            params["sftp-password"]       = s.get("password", "")
            params["sftp-root-directory"] = s.get("root-directory", "/")
            params["sftp-directory"]      = s.get("directory", "")
            # Explicit upload/download flips. libguac-client-vnc
            # defaults both to false (i.e. allowed), but setting
            # them explicitly here guarantees an operator can:
            #   - drag a file from their local OS onto the
            #     Guacamole canvas → uploads via SFTP to
            #     sftp-directory (i.e. ~/Downloads on Kali);
            #   - open the Guacamole side panel (Ctrl+Alt+Shift)
            #     → Devices section → file browser → download
            #     anything under sftp-root-directory back to
            #     their local machine.
            # If a manifest entry explicitly sets disable-upload
            # or disable-download to True, we honor that (some
            # student-facing connections might want read-only).
            params["sftp-disable-upload"]   = "true" if s.get("disable-upload", False)   else "false"
            params["sftp-disable-download"] = "true" if s.get("disable-download", False) else "false"
        if c["protocol"] == "rdp":
            # Security mode depends on the RDP server family:
            #   Windows RDP  -> NLA (CredSSP)  -- the modern default
            #   Linux xrdp   -> "any"          -- xrdp can't do NLA;
            #                                    NLA causes
            #                                    "libxrdp_force_read:
            #                                    header read error"
            #                                    in the xrdp log.
            # We detect Linux RDP via os field (kali / any non-windows-*).
            is_linux_rdp = not (c.get("os","") or "").startswith("windows")

            # Drive-redirection split:
            #   - Windows RDP   → ENABLED with a real drive-path so
            #                     operators can drag files in/out of
            #                     the RDP session. Mounts as a network
            #                     drive named "Guacamole" inside the
            #                     Windows session.
            #   - Linux xrdp    → DISABLED. xrdp's chansrv has a bug
            #                     where an empty drive-path triggers
            #                     `Unable to create directory ""`,
            #                     leaves the RDPDR channel half-up,
            #                     and the server fires
            #                     DisconnectProviderUltimatum 1-2s
            #                     after a successful XFCE login.
            #                     Linux RDP hosts get the SFTP
            #                     overlay above instead (same UX —
            #                     drop a file on the canvas →
            #                     uploads via SSH).
            #
            # drive-path lives on the guacd container's filesystem;
            # /tmp/guacd-drives/<connection_name>/ is a per-connection
            # staging area Guacamole creates and the operator never
            # sees directly (the FILES are streamed to/from the
            # Windows session, not stored permanently on guacd).
            rdp_params = {
              "security":      "any" if is_linux_rdp else "nla",
              "ignore-cert":   "true",
              # resize-method DELIBERATELY NOT SET.
              # Previously "display-update": every browser resize
              # asked the Windows server to renegotiate the desktop
              # resolution mid-session, which (a) caused the
              # wallpaper to re-stretch every time the operator
              # adjusted the tab and (b) added visible flicker.
              # Omitting the parameter pins the server desktop at
              # whatever resolution Guacamole's web client sent at
              # connect time (the browser viewport size) — stable
              # for the lifetime of the connection. If the operator
              # resizes the browser later, the Guac canvas
              # CSS-scales to fit, the server desktop never moves.
              # No more wallpaper-rendering churn.
              "enable-drive":       "false" if is_linux_rdp else "true",
              "create-drive-path":  "false" if is_linux_rdp else "true",
              "drive-path":         "" if is_linux_rdp else f"/tmp/guacd-drives/{c['name'].replace(' ', '_').replace('(', '').replace(')', '')}",
              "drive-name":         "" if is_linux_rdp else "Guacamole",
              "server-layout":            "en-us-qwerty",
              # color-depth 32 = true color + alpha. Default RDP is
              # 16-bit ("high color"), which makes the CWR
              # wallpaper look banded/dithered (gradients turn
              # blocky). 32-bit is the modern Windows-RDP default
              # and what every native client (mstsc, FreeRDP) uses
              # — no measurable bandwidth penalty after RDP's
              # RemoteFX compression kicks in.
              "color-depth":              "32",
              # disable-wallpaper / disable-theming DELIBERATELY
              # NOT SET (were "true").
              # Those two flags ask the RDP server to send a solid
              # color background AND suppress Aero/Fluent theme
              # rendering as a bandwidth optimization — but they
              # completely override the HKLM Policies\System
              # Wallpaper that the windows-base ansible role sets.
              # Result: operator RDPs in via Guac and sees a black
              # void instead of the CWR branding, regardless of
              # how clean the policy is on the server side. With
              # both flags removed, RDP honors the Wallpaper
              # policy normally; bandwidth cost on a 1080p canvas
              # is ~50-100 KB on the first frame and zero
              # thereafter (RDP only re-streams the desktop on
              # damage).
              "disable-full-window-drag": "true",
              "disable-menu-animations":  "true",
            }
            # For domain-joined connections the username arrives as
            # "NETBIOS\\user" — split and use the `domain` param.
            if "\\" in c["username"]:
                dom, user = c["username"].split("\\", 1)
                rdp_params["domain"]   = dom
                rdp_params["username"] = user
                params["username"]     = user
                params["domain"]       = dom
            params.update(rdp_params)
        payload = {
          "parentIdentifier": group_ids.get(c["student_id"], "ROOT"),
          "name": c["name"],
          "protocol": c["protocol"],
          "parameters": params,
          "attributes": {"max-connections": "10"}
        }

        # UPSERT: if a connection with this name already exists,
        # PUT to update its parameters (refreshes stale passwords
        # from earlier runs). Otherwise POST to create. Previously
        # we skipped existing connections, which meant rotating
        # the auto-generated random_password.* values broke every
        # registered connection until the operator re-registered
        # manually.
        if c["name"] in conn_name_to_id:
            existing_id = conn_name_to_id[c["name"]]
            status, body = req(
                "PUT",
                f"/api/session/data/postgresql/connections/{existing_id}",
                token=token, payload=payload)
            if status in (200, 204):
                created_conns.append((c, existing_id))
                print(f"[update] {c['name']}")
            else:
                print(f"[!] update {c['name']} returned {status}: {body}")
                created_conns.append((c, existing_id))
            continue

        status, body = req("POST",
                           "/api/session/data/postgresql/connections",
                           token=token, payload=payload)
        if isinstance(body, dict) and "identifier" in body:
            created_conns.append((c, body["identifier"]))

    # Pre-compute the shared-infra group identifier (if any).
    # Connections with student_id="shared-infra" — ELK, Ghostwriter,
    # SteppingStones, RedELK, the kali-2 ephemeral workspace pool —
    # are broadcast to EVERY per-student operator. Rationale:
    # redteam ranges are collaborative; the per-student boundary
    # exists so operators don't trample each other's domain creds,
    # but the shared services (logging, reporting, workspaces) are
    # everyone's. In single-student mode (no `students` block) the
    # admin sees everything anyway and this is a no-op.
    shared_infra_gid = group_ids.get("shared-infra")
    shared_infra_conn_ids = [
        cid for c, cid in created_conns
        if c.get("student_id") == "shared-infra"
    ]

    # Create per-student users. Each user can READ their own group only.
    for su in m.get("students", []):
        # Create user (PUT password if exists)
        req("POST", "/api/session/data/postgresql/users", token=token,
            payload={"username": su["username"],
                     "password": su["password"], "attributes": {}})
        # Grant READ on the student's connection group.
        gid = group_ids.get(su["student_id"])
        if not gid:
            continue
        req("PATCH",
            f"/api/session/data/postgresql/users/{su['username']}/permissions",
            token=token,
            payload=[{
                "op": "add",
                "path": f"/connectionGroupPermissions/{gid}",
                "value": "READ"
            }])
        # Also grant READ on each connection in that group.
        for c, cid in created_conns:
            if c["student_id"] != su["student_id"]:
                continue
            req("PATCH",
                f"/api/session/data/postgresql/users/{su['username']}/permissions",
                token=token,
                payload=[{
                    "op": "add",
                    "path": f"/connectionPermissions/{cid}",
                    "value": "READ"
                }])

        # Broadcast: also grant READ on the shared-infra group and
        # every connection inside it (ELK, Ghostwriter, RedELK,
        # SteppingStones, kali-2 ephemeral workspace pool). See
        # rationale on shared_infra_gid above.
        if shared_infra_gid:
            req("PATCH",
                f"/api/session/data/postgresql/users/{su['username']}/permissions",
                token=token,
                payload=[{
                    "op": "add",
                    "path": f"/connectionGroupPermissions/{shared_infra_gid}",
                    "value": "READ"
                }])
        for shared_cid in shared_infra_conn_ids:
            req("PATCH",
                f"/api/session/data/postgresql/users/{su['username']}/permissions",
                token=token,
                payload=[{
                    "op": "add",
                    "path": f"/connectionPermissions/{shared_cid}",
                    "value": "READ"
                }])

    print("registration complete")

if __name__ == "__main__":
    main()
