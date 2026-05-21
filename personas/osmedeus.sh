#!/usr/bin/env bash
# =============================================================================
# Persona: osmedeus
# =============================================================================
# Theme   : Headless scanner box for web-app + API consulting. Runs
#           Osmedeus as a long-lived service with its web UI on :8000
#           (intra-VNet only — no public IP), pre-loaded with the
#           ProjectDiscovery toolkit and the common API-testing CLIs
#           so a fresh range is ready to scan without manual setup.
# Source  : https://github.com/j3ssie/osmedeus
# OS      : Debian 12 / Ubuntu 22.04 (the persona runs as root via cloud-init)
# Role    : linux-target  (lives in the targets subnet; reachable from
#           the attacker-subnet Kali boxes over intra-VNet routing)
#
# What gets installed:
#   - Go toolchain (latest stable)
#   - Osmedeus binary + osmedeus-base workflows
#   - Nuclei + current templates
#   - ProjectDiscovery: httpx, subfinder, katana, dnsx, naabu, interactsh
#   - Other Go staples: ffuf, feroxbuster (apt), dalfox, gau, waybackurls,
#                       assetfinder, hakrawler, jaeles, anew, qsreplace
#   - Python tooling: arjun, paramspider, xsstrike (via pipx)
#   - API testing: newman (Postman CLI), swagger-cli, hurl, mitmproxy,
#                  httpie, jq
#   - Caido CLI (optional)
#
# What gets configured:
#   - systemd unit `osmedeus-server` running the web UI on :8000
#   - `/srv/scans/`           — drop target lists / Postman collections here
#   - `/srv/scans/incoming/`  — wrapper polls this for new jobs (optional)
#   - `/srv/scans/results/`   — Osmedeus + Newman outputs land here
#   - Daily systemd-timer that runs `nuclei -update-templates` and
#     `osmedeus update --vuln`
#   - MOTD with quick-start examples
#
# How to reach the scanner from a Kali analyst box (via Guacamole RDP):
#   1. Open Firefox on Kali
#   2. Navigate to https://10.<student>.0.<scanner-octet>:8000
#      (private IP printed in the per-engagement creds file)
#   3. Log in: admin / <password printed below + in /opt/osmedeus/.creds>

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'
banner() { echo -e "\n${CYN}${BLD}[*] $1${RST}"; }
ok()     { echo -e "${GRN}[+] $1${RST}"; }
warn()   { echo -e "${YEL}[!] $1${RST}"; }
err()    { echo -e "${RED}[x] $1${RST}"; }

[[ $EUID -ne 0 ]] && { err "Run as root."; exit 1; }

LOGFILE=/var/log/osmedeus_persona.log
exec > >(tee -a "$LOGFILE") 2>&1

SCAN_USER="${SCAN_USER:-ranger}"
SCAN_HOME=$(getent passwd "$SCAN_USER" | cut -d: -f6 || true)
[[ -z "${SCAN_HOME:-}" || ! -d "$SCAN_HOME" ]] && {
  err "Cannot resolve home for $SCAN_USER — is the user created by cloud-init?"
  exit 1
}
LAB_IP=$(hostname -I | awk '{print $1}')

banner "PHASE 0 — packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl wget git jq vim tmux net-tools \
  build-essential pkg-config libpcap-dev \
  python3-pip pipx \
  npm \
  ffuf feroxbuster amass mitmproxy hurl httpie nikto \
  unzip xz-utils 2>/dev/null || warn "Some apt packages missing on this release"

# ---- Go toolchain ----------------------------------------------------------
# Debian's golang-go can lag a major release behind. Osmedeus + ProjectDiscovery
# both need recent Go (>= 1.21). Install the upstream tarball into /usr/local/go.
banner "PHASE 1 — Go toolchain"
if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
  GO_VER=1.23.4
  case "$(uname -m)" in
    x86_64|amd64)  GO_ARCH=amd64 ;;
    aarch64|arm64) GO_ARCH=arm64 ;;
    *) err "Unsupported arch $(uname -m)"; exit 1 ;;
  esac
  curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi
ln -sf /usr/local/go/bin/go    /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
ok "Go: $(go version)"

# Per-user GOPATH so `go install` lands under the scan user's home.
sudo -u "$SCAN_USER" mkdir -p "$SCAN_HOME/go/bin"
cat > /etc/profile.d/cwr-osmedeus.sh <<'EOF'
export GOPATH="$HOME/go"
export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"
EOF
chmod 644 /etc/profile.d/cwr-osmedeus.sh
export GOPATH="$SCAN_HOME/go"
export PATH="/usr/local/go/bin:$SCAN_HOME/go/bin:$PATH"

go_install_as_scanner() {
  local pkg="$1"
  sudo -u "$SCAN_USER" \
    HOME="$SCAN_HOME" GOPATH="$SCAN_HOME/go" \
    PATH="/usr/local/go/bin:$SCAN_HOME/go/bin:$PATH" \
    go install "$pkg" 2>&1 | tail -3 || warn "go install $pkg failed (continuing)"
}

# ---- Osmedeus -------------------------------------------------------------
banner "PHASE 2 — Osmedeus"
if ! sudo -u "$SCAN_USER" bash -lc "command -v osmedeus" >/dev/null 2>&1; then
  go_install_as_scanner "github.com/j3ssie/osmedeus@latest"
fi
# Pre-fetch the osmedeus-base workflow repo so the first scan doesn't
# stall while the framework clones it from GitHub. The `update --vuln`
# subcommand pulls both the base workflows and the vuln signatures.
sudo -u "$SCAN_USER" bash -lc 'osmedeus update --vuln' 2>&1 | tail -10 \
  || warn "osmedeus update --vuln failed — run interactively for diagnostics"
ok "Osmedeus installed for $SCAN_USER (workflows in $SCAN_HOME/.osmedeus/)"

# ---- ProjectDiscovery + curated webapp toolkit ----------------------------
banner "PHASE 3 — ProjectDiscovery + webapp toolkit"
for tool in \
  "nuclei|github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" \
  "httpx|github.com/projectdiscovery/httpx/cmd/httpx@latest" \
  "subfinder|github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" \
  "katana|github.com/projectdiscovery/katana/cmd/katana@latest" \
  "dnsx|github.com/projectdiscovery/dnsx/cmd/dnsx@latest" \
  "naabu|github.com/projectdiscovery/naabu/v2/cmd/naabu@latest" \
  "interactsh-client|github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest" \
  "dalfox|github.com/hahwul/dalfox/v2@latest" \
  "gau|github.com/lc/gau/v2/cmd/gau@latest" \
  "waybackurls|github.com/tomnomnom/waybackurls@latest" \
  "assetfinder|github.com/tomnomnom/assetfinder@latest" \
  "hakrawler|github.com/hakluke/hakrawler@latest" \
  "gf|github.com/tomnomnom/gf@latest" \
  "anew|github.com/tomnomnom/anew@latest" \
  "qsreplace|github.com/tomnomnom/qsreplace@latest" \
  "unfurl|github.com/tomnomnom/unfurl@latest" \
  "jaeles|github.com/jaeles-project/jaeles@latest"; do
  name="${tool%%|*}"; path="${tool#*|}"
  if ! sudo -u "$SCAN_USER" bash -lc "command -v $name" >/dev/null 2>&1; then
    go_install_as_scanner "$path"
  fi
done

# Pre-update nuclei templates so first scan is fast
sudo -u "$SCAN_USER" bash -lc 'nuclei -ut -silent' 2>&1 | tail -3 \
  || warn "nuclei -ut failed (network egress?)"

# gf patterns
sudo -u "$SCAN_USER" mkdir -p "$SCAN_HOME/.gf"
sudo -u "$SCAN_USER" git clone --depth 1 \
  https://github.com/tomnomnom/gf "$SCAN_HOME/.gf-src" 2>/dev/null || true
[[ -d "$SCAN_HOME/.gf-src/examples" ]] && \
  sudo -u "$SCAN_USER" cp -r "$SCAN_HOME/.gf-src/examples/." "$SCAN_HOME/.gf/" 2>/dev/null || true
sudo -u "$SCAN_USER" git clone --depth 1 \
  https://github.com/1ndianl33t/Gf-Patterns "$SCAN_HOME/.gf-extra" 2>/dev/null || true
[[ -d "$SCAN_HOME/.gf-extra" ]] && \
  sudo -u "$SCAN_USER" cp "$SCAN_HOME"/.gf-extra/*.json "$SCAN_HOME/.gf/" 2>/dev/null || true

# ---- Python tooling -------------------------------------------------------
banner "PHASE 4 — Python tooling"
sudo -u "$SCAN_USER" bash -lc '
  pipx ensurepath >/dev/null 2>&1 || true
  for pkg in arjun xsstrike paramspider; do
    if ! pipx list 2>/dev/null | grep -qi "$pkg"; then
      pipx install "$pkg" 2>/dev/null \
        || pip install --user --break-system-packages "$pkg" 2>/dev/null \
        || true
    fi
  done
'

# LinkFinder + SecretFinder (clone-only, run via python3)
mkdir -p "$SCAN_HOME/Tools"
for repo in \
  "LinkFinder|https://github.com/GerbenJavado/LinkFinder.git" \
  "SecretFinder|https://github.com/m4ll0k/SecretFinder.git"; do
  name="${repo%%|*}"; url="${repo#*|}"
  dest="$SCAN_HOME/Tools/$name"
  [[ -d "$dest" ]] || sudo -u "$SCAN_USER" git clone --depth 1 "$url" "$dest" 2>/dev/null || true
done

# ---- API testing tooling --------------------------------------------------
banner "PHASE 5 — API testing tooling"
# Postman CLI runner + Swagger validator (Node)
npm install -g newman swagger-cli openapi-cli-tool 2>&1 | tail -3 \
  || warn "npm global install failed"
# httpie, hurl, mitmproxy already installed above via apt.

# RESTler-like / stateful API fuzzing — note for the operator.
# We don't auto-install Microsoft RESTler here (heavy .NET runtime
# requirement). The README points at the right place if needed.

# ---- Scan directories + permissions ---------------------------------------
banner "PHASE 6 — scan-job filesystem"
mkdir -p /srv/scans/{incoming,running,results,collections,wordlists,targets}
chown -R "$SCAN_USER:$SCAN_USER" /srv/scans
chmod 0750 /srv/scans
cat > /srv/scans/README.md <<EOF
# /srv/scans/ — scanner workdir layout

  targets/       drop \`*.txt\` files of hosts/URLs (one per line)
  collections/   drop Postman / OpenAPI / Swagger JSON files here
  wordlists/     custom wordlists if you don't want SecLists defaults
  incoming/      (optional) wrapper polls here for queued scan-job specs
  running/       in-flight scan dirs (Osmedeus state)
  results/       per-job result dirs (Osmedeus reports + Newman JUnit XML)

Quick scan recipes — see /etc/motd or the README on each Kali analyst box.
EOF
chown "$SCAN_USER:$SCAN_USER" /srv/scans/README.md

# ---- Osmedeus credentials + server systemd unit ---------------------------
banner "PHASE 7 — Osmedeus server (systemd)"
# Generate a random Osmedeus admin password and stash it where the
# operator can `cat` it after deploy. Anyone with shell on the box can
# read this file — that's fine, the analyst Kali boxes are the only
# things that can route to this VM.
mkdir -p /opt/osmedeus
if [[ ! -s /opt/osmedeus/.creds ]]; then
  OSMEDEUS_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
  cat > /opt/osmedeus/.creds <<EOF
osmedeus_user=admin
osmedeus_password=${OSMEDEUS_PASS}
osmedeus_url=https://${LAB_IP}:8000
EOF
  chmod 0640 /opt/osmedeus/.creds
  chown root:"$SCAN_USER" /opt/osmedeus/.creds
fi
source /opt/osmedeus/.creds

# Seed the Osmedeus admin account. `osmedeus account --new` is the
# documented bootstrap path; older versions used `--update` for an
# existing user. We try `--new` then fall back to `--update` so a
# re-run of this persona (e.g. cloud-init replay) keeps the password
# in sync with what's in /opt/osmedeus/.creds.
sudo -u "$SCAN_USER" bash -lc \
  "osmedeus account --new --user admin --pass '${osmedeus_password}'" \
  2>&1 | tail -3 \
  || sudo -u "$SCAN_USER" bash -lc \
       "osmedeus account --update --user admin --pass '${osmedeus_password}'" \
       2>&1 | tail -3 \
  || warn "osmedeus account create failed — first-launch will prompt"

cat > /etc/systemd/system/osmedeus-server.service <<EOF
[Unit]
Description=Osmedeus headless scanner + web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SCAN_USER}
Group=${SCAN_USER}
Environment=HOME=${SCAN_HOME}
Environment=PATH=/usr/local/go/bin:${SCAN_HOME}/go/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=${SCAN_HOME}

# Rate-limit defaults sourced by both the server and the wrappers so
# osmedeus-internal runs respect the same caps wrapper invocations do.
EnvironmentFile=-/etc/cwr/scan-limits.env

ExecStart=${SCAN_HOME}/go/bin/osmedeus server -A 0.0.0.0 -P 8000
Restart=on-failure
RestartSec=10

# ---- Resource caps -------------------------------------------------------
# Hard guard-rails so a runaway workflow can't OOM the VM or saturate
# every core. B4ms = 4 vCPU / 16 GB; we cap at 75% of each so the box
# stays responsive for SSH / Guacamole + concurrent Newman / mitmproxy
# work. Bump these if you size up to B8ms (8 vCPU / 32 GB).
MemoryMax=12G
MemoryHigh=10G
CPUQuota=300%
TasksMax=4096
LimitNOFILE=65536
KillMode=mixed
TimeoutStopSec=120s
IPAccounting=true

# ---- Sandbox (safe-for-osmedeus subset) ----------------------------------
# Osmedeus spawns many Go subprocesses doing arbitrary network I/O, so
# we can't lock down ProtectSystem=strict or PrivateNetwork. The flags
# below are the safe additions — no known interaction with osmedeus's
# workflows or sub-tooling.
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
PrivateTmp=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now osmedeus-server.service
ok "osmedeus-server enabled — UI on https://${LAB_IP}:8000"

# ---- Scheduled template + workflow refreshes ------------------------------
banner "PHASE 8 — daily template refresh (systemd timer)"
cat > /etc/systemd/system/cwr-scanner-refresh.service <<EOF
[Unit]
Description=Refresh nuclei templates + osmedeus workflows
[Service]
Type=oneshot
User=${SCAN_USER}
Group=${SCAN_USER}
Environment=HOME=${SCAN_HOME}
Environment=PATH=/usr/local/go/bin:${SCAN_HOME}/go/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash -c 'nuclei -ut -silent; osmedeus update --vuln'
EOF
cat > /etc/systemd/system/cwr-scanner-refresh.timer <<'EOF'
[Unit]
Description=Daily template/workflow refresh for the CWR scanner box
[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now cwr-scanner-refresh.timer
ok "Daily refresh scheduled (cwr-scanner-refresh.timer)"

# ---- Rate-limit + scope-enforcement config --------------------------------
banner "PHASE 9a — safe-default rate limits + scope file"
# Conservative defaults chosen so that an untouched scan stays well
# below typical WAF / rate-limiter thresholds. Operators who need to
# turn them up for a tolerant lab target can `export NUCLEI_RPS=200`
# (etc.) before invoking the wrappers, or edit /etc/cwr/scan-limits.env
# for a persistent override. NEVER raise these for client traffic
# without written authorisation.
mkdir -p /etc/cwr
cat > /etc/cwr/scan-limits.env <<'EOF'
# CWR scanner — conservative rate-limit defaults.
# All numbers are per-tool, not cumulative; with two scans running in
# parallel you'll see roughly 2x these values on the wire.

# nuclei: requests / second, concurrent templates, batched hosts.
# Default upstream is rl=150 c=25 bs=25 — we drop rl by 5x.
NUCLEI_RPS=30
NUCLEI_CONCURRENCY=25
NUCLEI_BULK_SIZE=10
NUCLEI_TIMEOUT=10
NUCLEI_RETRIES=1
NUCLEI_MAX_HOST_ERROR=20

# httpx: probe rate. Default upstream is 150; 50 is gentle.
HTTPX_RATE_LIMIT=50
HTTPX_THREADS=25

# ffuf / feroxbuster: explicit rate so brute-force enums don't hammer.
FFUF_RATE=30
FFUF_THREADS=25
FEROX_RATE=30
FEROX_THREADS=10

# Newman: delay between requests (ms). Postman collections often
# include sequence-dependent calls; a 200ms delay smooths bursts
# without changing observed behaviour.
NEWMAN_DELAY_MS=200

# Osmedeus scan-wide timeout (seconds). Hard kill if a workflow runs
# longer than this. 6 hours by default.
OSMEDEUS_MAX_RUNTIME=21600

# Refuse to scan unless the target appears in /srv/scans/scope.txt.
# Set to 0 only for self-owned lab targets. CLIENT WORK MUST BE 1.
ENFORCE_SCOPE=1
EOF
chmod 0644 /etc/cwr/scan-limits.env

# Empty scope file — the wrappers refuse to scan anything not listed
# here when ENFORCE_SCOPE=1. Format: one host or wildcard per line.
#   target.example.com
#   *.staging.example.com
#   10.0.0.0/24            (CIDR for IP-based scopes)
cat > /srv/scans/scope.txt <<'EOF'
# CWR scanner — IN-SCOPE TARGETS (one per line)
# ------------------------------------------------
# The runscan-* wrappers refuse to run against any host NOT listed
# here when /etc/cwr/scan-limits.env sets ENFORCE_SCOPE=1.
#
# Format:
#   host.example.com           literal hostname
#   *.staging.example.com      wildcard subdomain match
#   10.0.0.0/24                CIDR for IP-based scopes
#   # comments start with hash
#
# Update at engagement kickoff, commit the file to the engagement
# evidence directory, and clear it at end of engagement (a fresh
# scenario apply seeds it empty).
EOF
chown "$SCAN_USER:$SCAN_USER" /srv/scans/scope.txt
chmod 0644 /srv/scans/scope.txt

# scope-check: extracts the host from a URL, then matches against
# /srv/scans/scope.txt with literal / wildcard / CIDR support.
# Exits 0 on in-scope, 1 on out-of-scope or empty scope file.
cat > /usr/local/bin/scope-check <<'BASH'
#!/usr/bin/env bash
# scope-check <target>
# Returns 0 if target is in /srv/scans/scope.txt, else non-zero.
# Honours wildcards (*.example.com) and CIDRs.
set -euo pipefail
target_raw="${1:-}"
[[ -z "$target_raw" ]] && { echo "usage: scope-check <target>" >&2; exit 2; }

# Strip scheme, port, path → bare host. Also pin to a conservative
# charset (host-legal characters only) so the value is safe to pass
# through pipelines without injection.
host=$(printf '%s\n' "$target_raw" \
       | sed -E 's#^[a-zA-Z]+://##; s#/.*##; s#:[0-9]+$##' \
       | tr -d -c 'A-Za-z0-9.-')
[[ -z "$host" ]] && { echo "[scope-check] empty/invalid host after sanitise: $target_raw" >&2; exit 2; }

SCOPE_FILE=${SCOPE_FILE:-/srv/scans/scope.txt}
if [[ ! -s "$SCOPE_FILE" ]] || ! grep -qvE '^\s*(#|$)' "$SCOPE_FILE" 2>/dev/null; then
  echo "[scope-check] scope file is empty or missing entries: $SCOPE_FILE" >&2
  exit 1
fi

cidr_match() {
  # Pass host + cidr through argv, not shell interpolation, to keep
  # any odd characters out of the python source. (Belt + braces — the
  # tr above already restricted the charset.)
  python3 - "$1" "$2" <<'PY'
import ipaddress, socket, sys
host, cidr = sys.argv[1], sys.argv[2]
try:
    ip = ipaddress.ip_address(socket.gethostbyname(host))
    net = ipaddress.ip_network(cidr, strict=False)
    sys.exit(0 if ip in net else 1)
except Exception:
    sys.exit(1)
PY
}

while IFS= read -r line; do
  entry=$(printf '%s\n' "$line" | sed -E 's/#.*$//; s/^\s+//; s/\s+$//')
  [[ -z "$entry" ]] && continue

  # CIDR (contains /, numeric+dot prefix)
  if [[ "$entry" =~ ^[0-9.]+/[0-9]+$ ]]; then
    cidr_match "$host" "$entry" && exit 0
    continue
  fi

  # Wildcard (*.example.com)
  if [[ "$entry" == \*.* ]]; then
    suffix=${entry#\*}
    [[ "$host" == *"$suffix" ]] && exit 0
    continue
  fi

  # Literal hostname match
  [[ "$host" == "$entry" ]] && exit 0
done < "$SCOPE_FILE"

echo "[scope-check] $host not in $SCOPE_FILE" >&2
exit 1
BASH
chmod +x /usr/local/bin/scope-check

# scan-lock: per-target advisory lock so the same host can't be hammered
# by two concurrent wrappers. Used as the first thing inside every
# runscan-* wrapper. The lock file path is hashed so the lock dir
# stays small and the path is safe even for absurd target strings.
cat > /usr/local/bin/scan-lock <<'BASH'
#!/usr/bin/env bash
# scan-lock <target>
# Prints the lock fd setup commands to stdout — source via eval(). The
# wrapper holds the lock for the lifetime of its own process.
set -euo pipefail
target="${1:?usage: scan-lock <target>}"
target_hash=$(printf '%s' "$target" | sha1sum | cut -c1-12)
LOCKDIR=/run/cwr
mkdir -p "$LOCKDIR" 2>/dev/null || true
chmod 0775 "$LOCKDIR" 2>/dev/null || true
echo "$LOCKDIR/scan-$target_hash.lock"
BASH
chmod +x /usr/local/bin/scan-lock

# ---- Helper wrappers for common scans -------------------------------------
banner "PHASE 9b — wrapper scripts (rate-limited + scope-gated)"
# All wrappers:
#   * source /etc/cwr/scan-limits.env for current rate / scope policy
#   * scope-check the target unless --no-scope-check is passed
#   * apply nuclei/httpx/etc. rate-limit flags from env
#   * timeout(1)-wrap the underlying tool against OSMEDEUS_MAX_RUNTIME
#   * never use ffuf/feroxbuster/sqlmap directly — these are too easy
#     to point at a target and forget about. Operators run those by
#     hand with explicit args.

cat > /usr/local/bin/runscan-quick <<'EOF'
#!/usr/bin/env bash
# runscan-quick <target> [--no-scope-check] [--aggressive]
# Nuclei pass with high+critical templates, rate-limited per /etc/cwr/scan-limits.env.
set -euo pipefail
source /etc/cwr/scan-limits.env

target=""; no_scope=0; aggressive=0
for arg in "$@"; do
  case "$arg" in
    --no-scope-check) no_scope=1 ;;
    --aggressive)     aggressive=1 ;;
    --*)              echo "unknown flag: $arg"; exit 2 ;;
    *) [[ -z "$target" ]] && target="$arg" || { echo "extra arg: $arg"; exit 2; } ;;
  esac
done
[[ -z "$target" ]] && { echo "usage: runscan-quick <target> [--no-scope-check] [--aggressive]"; exit 2; }

if [[ "${ENFORCE_SCOPE:-1}" == 1 && "$no_scope" == 0 ]]; then
  scope-check "$target" || { echo "[!] target out of scope. Edit /srv/scans/scope.txt or re-run with --no-scope-check"; exit 3; }
fi

# Per-target lock — refuse to start a second wrapper against the same
# host. Different hosts run in parallel; identical hosts serialise.
LOCKFILE=$(scan-lock "$target")
exec 9>"$LOCKFILE"
flock --nonblock 9 || { echo "[!] $target is already being scanned (lock $LOCKFILE held). Exiting."; exit 4; }

# Aggressive flag bumps to upstream defaults — use ONLY on self-owned
# lab targets with no rate-limit / WAF policy. Will not bypass the
# scope check.
if [[ "$aggressive" == 1 ]]; then
  NUCLEI_RPS=150; NUCLEI_CONCURRENCY=25; NUCLEI_BULK_SIZE=25
  echo "[!] --aggressive: running at upstream defaults ($NUCLEI_RPS rps). Confirm you have authorisation."
fi

out=/srv/scans/results/quick-$(date +%Y%m%d-%H%M%S)-${target//[^a-zA-Z0-9]/_}
mkdir -p "$out"; chown ranger:ranger "$out"
echo "[+] nuclei rl=$NUCLEI_RPS c=$NUCLEI_CONCURRENCY bs=$NUCLEI_BULK_SIZE -> $out"
timeout "${OSMEDEUS_MAX_RUNTIME}" \
  sudo -u ranger -E nuclei \
    -u "$target" \
    -severity critical,high -es info \
    -rl  "$NUCLEI_RPS" \
    -c   "$NUCLEI_CONCURRENCY" \
    -bs  "$NUCLEI_BULK_SIZE" \
    -timeout "$NUCLEI_TIMEOUT" \
    -retries "$NUCLEI_RETRIES" \
    -mhe "$NUCLEI_MAX_HOST_ERROR" \
    -stats \
    -o   "$out/nuclei.txt" \
    -j   -se "$out/nuclei.json"
echo "Results: $out"
EOF

cat > /usr/local/bin/runscan-full <<'EOF'
#!/usr/bin/env bash
# runscan-full <target> [--no-scope-check] [--aggressive]
# Osmedeus general workflow. Capped at OSMEDEUS_MAX_RUNTIME (default 6h).
set -euo pipefail
source /etc/cwr/scan-limits.env

target=""; no_scope=0; aggressive=0
for arg in "$@"; do
  case "$arg" in
    --no-scope-check) no_scope=1 ;;
    --aggressive)     aggressive=1 ;;
    --*)              echo "unknown flag: $arg"; exit 2 ;;
    *) [[ -z "$target" ]] && target="$arg" || { echo "extra arg: $arg"; exit 2; } ;;
  esac
done
[[ -z "$target" ]] && { echo "usage: runscan-full <target> [--no-scope-check] [--aggressive]"; exit 2; }

if [[ "${ENFORCE_SCOPE:-1}" == 1 && "$no_scope" == 0 ]]; then
  scope-check "$target" || { echo "[!] target out of scope. Edit /srv/scans/scope.txt or re-run with --no-scope-check"; exit 3; }
fi

# Per-target lock — see runscan-quick.
LOCKFILE=$(scan-lock "$target")
exec 9>"$LOCKFILE"
flock --nonblock 9 || { echo "[!] $target is already being scanned (lock $LOCKFILE held). Exiting."; exit 4; }

# Default workflow: 'general' is Osmedeus's lighter recon profile.
# `--aggressive` switches to the heavier 'vuln' workflow which kicks
# off jaeles / nuclei / dirsearch in parallel. Only use on lab.
workflow=general
[[ "$aggressive" == 1 ]] && workflow=vuln && echo "[!] --aggressive: running 'vuln' workflow. Confirm authorisation."

out=/srv/scans/results/full-$(date +%Y%m%d-%H%M%S)-${target//[^a-zA-Z0-9]/_}
echo "[+] osmedeus workflow=$workflow timeout=${OSMEDEUS_MAX_RUNTIME}s -> $out"
timeout "${OSMEDEUS_MAX_RUNTIME}" \
  sudo -u ranger -E bash -lc \
    "osmedeus scan -f '$workflow' -t '$target' -o '$out'"
echo "Results: $out"
EOF

cat > /usr/local/bin/runscan-api <<'EOF'
#!/usr/bin/env bash
# runscan-api <spec.json> <base-url> [--no-scope-check]
# Stateful API assessment:
#   1. swagger-cli validate or Newman run (depending on spec type)
#   2. nuclei with API-focused tags, rate-limited
# Newman runs with NEWMAN_DELAY_MS between requests to avoid bursts.
set -euo pipefail
source /etc/cwr/scan-limits.env

spec=""; base=""; no_scope=0
for arg in "$@"; do
  case "$arg" in
    --no-scope-check) no_scope=1 ;;
    --*)              echo "unknown flag: $arg"; exit 2 ;;
    *)
      if   [[ -z "$spec" ]]; then spec="$arg"
      elif [[ -z "$base" ]]; then base="$arg"
      else echo "extra arg: $arg"; exit 2
      fi ;;
  esac
done
[[ -z "$spec" || -z "$base" ]] && { echo "usage: runscan-api <spec.json> <base-url> [--no-scope-check]"; exit 2; }
[[ ! -f "$spec" ]] && { echo "spec not found: $spec"; exit 2; }

if [[ "${ENFORCE_SCOPE:-1}" == 1 && "$no_scope" == 0 ]]; then
  scope-check "$base" || { echo "[!] $base out of scope. Edit /srv/scans/scope.txt or re-run with --no-scope-check"; exit 3; }
fi

# Per-base-URL lock — same target shouldn't be hit by two concurrent API scans.
LOCKFILE=$(scan-lock "$base")
exec 9>"$LOCKFILE"
flock --nonblock 9 || { echo "[!] $base is already being scanned (lock $LOCKFILE held). Exiting."; exit 4; }

out=/srv/scans/results/api-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"; chown ranger:ranger "$out"

if jq -e '.info._postman_id' "$spec" >/dev/null 2>&1; then
  echo "[+] Postman collection — newman (delay ${NEWMAN_DELAY_MS}ms)"
  timeout "${OSMEDEUS_MAX_RUNTIME}" \
    sudo -u ranger newman run "$spec" \
      --env-var "base=$base" \
      --delay-request "${NEWMAN_DELAY_MS}" \
      -r cli,junit \
      --reporter-junit-export "$out/newman.junit.xml" \
    || echo "[!] newman exited non-zero (likely auth/sequence issues)"
elif jq -e '.openapi // .swagger' "$spec" >/dev/null 2>&1; then
  echo "[+] OpenAPI/Swagger — validate only (no fuzzing without scope confirmation)"
  swagger-cli validate "$spec" || echo "[!] spec validation reported issues"
else
  echo "[!] unrecognised spec format; skipping Newman/swagger-cli"
fi

echo "[+] nuclei API tags rl=$NUCLEI_RPS c=$NUCLEI_CONCURRENCY against $base"
timeout "${OSMEDEUS_MAX_RUNTIME}" \
  sudo -u ranger -E nuclei \
    -u "$base" \
    -tags exposed-panels,api,oast,token-spray,exposure \
    -es info \
    -rl  "$NUCLEI_RPS" \
    -c   "$NUCLEI_CONCURRENCY" \
    -bs  "$NUCLEI_BULK_SIZE" \
    -timeout "$NUCLEI_TIMEOUT" \
    -retries "$NUCLEI_RETRIES" \
    -mhe "$NUCLEI_MAX_HOST_ERROR" \
    -stats \
    -o   "$out/nuclei-api.txt" \
    -j   -se "$out/nuclei-api.json"
echo "Results: $out"
EOF

chmod +x /usr/local/bin/runscan-full /usr/local/bin/runscan-quick /usr/local/bin/runscan-api

# ---- Operator-quality-of-life helpers -------------------------------------
banner "PHASE 9d — operator helpers (scope / scan-status / package-evidence)"

# `scope` — manage /srv/scans/scope.txt without an editor
cat > /usr/local/bin/scope <<'BASH'
#!/usr/bin/env bash
# scope add <host>       Append host to /srv/scans/scope.txt (dedups)
# scope rm  <host>       Remove host from scope file
# scope list             Print current in-scope entries
# scope clear            Wipe scope (end-of-engagement)
# scope check <target>   Test scope without running a scan
set -euo pipefail
SCOPE_FILE=${SCOPE_FILE:-/srv/scans/scope.txt}
cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    entry="${1:?usage: scope add <host|*.dom|cidr>}"
    grep -qxF "$entry" "$SCOPE_FILE" || echo "$entry" >> "$SCOPE_FILE"
    echo "[+] scope: $entry"
    ;;
  rm|remove)
    entry="${1:?usage: scope rm <entry>}"
    tmp=$(mktemp); grep -vxF "$entry" "$SCOPE_FILE" > "$tmp" || true
    mv "$tmp" "$SCOPE_FILE"; chown ranger:ranger "$SCOPE_FILE"
    echo "[+] removed: $entry"
    ;;
  list|ls)
    awk 'NF && $1 !~ /^#/' "$SCOPE_FILE" || echo "(scope is empty)"
    ;;
  clear)
    : > "$SCOPE_FILE"; chown ranger:ranger "$SCOPE_FILE"
    echo "[+] scope cleared"
    ;;
  check)
    target="${1:?usage: scope check <target>}"
    scope-check "$target" && echo "[+] in scope" || { echo "[!] OUT of scope"; exit 1; }
    ;;
  ""|help|-h|--help)
    sed -nE '2,7p' "$0" | sed 's/^# *//'
    ;;
  *)
    echo "unknown subcommand: $cmd"; exit 2 ;;
esac
BASH
chmod +x /usr/local/bin/scope

# `scan-status` — show running wrappers, recent results, scope summary
cat > /usr/local/bin/scan-status <<'BASH'
#!/usr/bin/env bash
# scan-status — visibility on what the scanner is doing right now.
set -euo pipefail
echo "=== osmedeus-server ==="
systemctl is-active osmedeus-server || true
systemctl status osmedeus-server --no-pager -n 3 | sed 's/^/  /' | head -8

echo
echo "=== active scan locks ==="
shopt -s nullglob
locks=(/run/cwr/scan-*.lock)
if [[ ${#locks[@]} -eq 0 ]]; then
  echo "  (no active scans)"
else
  for f in "${locks[@]}"; do
    holder=$(fuser "$f" 2>/dev/null | awk '{print $NF}' || true)
    if [[ -n "$holder" ]]; then
      cmd=$(ps -o args= -p "$holder" 2>/dev/null | head -c 200)
      echo "  pid=$holder  $cmd"
    fi
  done
fi

echo
echo "=== scope file (/srv/scans/scope.txt) ==="
scope list 2>/dev/null | sed 's/^/  /' | head -20

echo
echo "=== last 5 result dirs ==="
ls -1dt /srv/scans/results/*/ 2>/dev/null | head -5 | sed 's/^/  /'

echo
echo "=== egress / disk ==="
df -h /srv | tail -1 | awk '{printf "  /srv: %s used of %s (%s)\n", $3, $2, $5}'
if command -v vnstat >/dev/null 2>&1; then
  vnstat --oneline 2>/dev/null | awk -F\; '{
    printf "  egress today: rx=%s tx=%s  | this month: rx=%s tx=%s\n", $4,$5,$9,$10
  }'
fi
BASH
chmod +x /usr/local/bin/scan-status

# `package-evidence` — tar up everything from an engagement for handoff.
# Captures scan results + scope file + scanner build log so the engagement
# package is reproducible.
cat > /usr/local/bin/package-evidence <<'BASH'
#!/usr/bin/env bash
# package-evidence <engagement-id> [pattern]
# Tars /srv/scans/results/<pattern>* (default: all), plus scope.txt and
# the persona install log, into /srv/scans/evidence-<id>-<ts>.tar.gz.
set -euo pipefail
id="${1:?usage: package-evidence <engagement-id> [result-prefix-pattern]}"
pattern="${2:-}"
ts=$(date +%Y%m%d-%H%M%S)
out=/srv/scans/evidence-${id}-${ts}.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/evidence-${id}-${ts}"
mkdir -p "$stage"

cp /srv/scans/scope.txt        "$stage/scope.txt"        2>/dev/null || true
cp /etc/cwr/scan-limits.env    "$stage/scan-limits.env"  2>/dev/null || true
cp /var/log/osmedeus_persona.log "$stage/install.log"    2>/dev/null || true

mkdir -p "$stage/results"
if [[ -n "$pattern" ]]; then
  cp -r /srv/scans/results/${pattern}* "$stage/results/" 2>/dev/null || true
else
  cp -r /srv/scans/results/* "$stage/results/" 2>/dev/null || true
fi

tar -C "$tmp" -czf "$out" "evidence-${id}-${ts}"
chown ranger:ranger "$out"
chmod 0640 "$out"
sha256sum "$out" | tee "${out}.sha256"
echo
echo "[+] Evidence package: $out"
echo "    SHA-256:           $(cut -d' ' -f1 < "${out}.sha256")"
echo "    Size:              $(du -h "$out" | cut -f1)"
BASH
chmod +x /usr/local/bin/package-evidence

# ---- Optional bulk: SecLists + vnstat -------------------------------------
banner "PHASE 9e — SecLists wordlists + egress accounting"

# SecLists clone — known wordlist path so wrappers / aliases can reference
# /opt/SecLists/Discovery/Web-Content/... without operator guessing. Big
# clone (~700 MB) but a one-time cost.
if [[ ! -d /opt/SecLists ]]; then
  git clone --depth 1 https://github.com/danielmiessler/SecLists.git /opt/SecLists 2>&1 | tail -3 \
    || warn "SecLists clone failed (offline? slow link?) — skip"
  chown -R "$SCAN_USER:$SCAN_USER" /opt/SecLists 2>/dev/null || true
fi

# vnstat — per-interface bandwidth accounting. Useful when an operator
# wants to see whether a scan moved 50 MB or 50 GB of egress.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vnstat 2>/dev/null || true
if command -v vnstatd >/dev/null 2>&1; then
  systemctl enable --now vnstat.service 2>/dev/null || \
  systemctl enable --now vnstatd.service 2>/dev/null || true
fi

# ---- Results-dir cleanup timer (disk pressure) ----------------------------
banner "PHASE 9c — disk-pressure cleanup timer"
cat > /etc/systemd/system/cwr-scan-cleanup.service <<'EOF'
[Unit]
Description=Prune /srv/scans/results older than 30 days
[Service]
Type=oneshot
ExecStart=/usr/bin/find /srv/scans/results -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
EOF
cat > /etc/systemd/system/cwr-scan-cleanup.timer <<'EOF'
[Unit]
Description=Weekly prune of old scan results
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now cwr-scan-cleanup.timer
ok "Weekly cleanup of /srv/scans/results enabled"

# ---- MOTD -----------------------------------------------------------------
cat > /etc/motd <<EOM
============================================================
  CWR Scanner — Osmedeus + ProjectDiscovery + API toolkit
------------------------------------------------------------
  Web UI:    https://${LAB_IP}:8000   (creds: cat /opt/osmedeus/.creds)
  Workdir:   /srv/scans/{targets,collections,results,scope.txt}

  >>> SAFETY DEFAULTS (very important for client work) <<<
    Scope gate:   /srv/scans/scope.txt   (wrappers refuse out-of-scope)
    Rate limits:  /etc/cwr/scan-limits.env
                  nuclei 30 rps / httpx 50 rps / newman 200ms delay
    Hard cap:     OSMEDEUS_MAX_RUNTIME=6h on every wrapper
    Edit limits:  sudoedit /etc/cwr/scan-limits.env  (then re-source)
    Bypass scope: --no-scope-check   (LOUD; only for lab targets)
    Aggressive:   --aggressive       (upstream rps; needs explicit auth)

  Scan wrappers (all rate-limited + scope-gated + per-target locked):
    runscan-quick  <target>                  nuclei crit+high
    runscan-full   <target>                  Osmedeus general workflow
    runscan-api    <spec.json> <base-url>    Postman/Swagger + nuclei

  Operator helpers:
    scope add <host>                         add to /srv/scans/scope.txt
    scope rm  <host>                         remove from scope
    scope list                               print in-scope entries
    scope check <target>                     test without scanning
    scan-status                              what's running, last results
    package-evidence <eng-id> [pattern]      tar.gz + sha256 for handoff

  Direct tool usage (operator-supplied flags only — defaults are aggressive):
    nuclei      -u https://target -severity critical,high -rl 30 -c 25
    osmedeus    scan -f general -t target.com
    newman      run /srv/scans/collections/coll.json --delay-request 200
    swagger-cli validate /srv/scans/collections/openapi.json
    mitmweb     --listen-host 0.0.0.0 --listen-port 8081

  Timers:
    cwr-scanner-refresh.timer   daily nuclei -ut + osmedeus update
    cwr-scan-cleanup.timer      weekly prune of results > 30 days

  Reach this box from the analyst Kali boxes over the per-engagement
  VNet — no public IP, no internet ingress.
============================================================
EOM

ok "Scanner persona ready. UI: https://${LAB_IP}:8000  user=admin"
