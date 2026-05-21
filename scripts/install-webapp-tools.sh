#!/usr/bin/env bash
# =============================================================================
# install-webapp-tools.sh
# =============================================================================
# Run as root on a Kali attacker box (kali01 / kali02 in the `consult`
# scenario) AFTER first-boot has finished installing kali-linux-default.
# Idempotent — safe to re-run.
#
#   sudo bash install-webapp-tools.sh           # full install
#   sudo bash install-webapp-tools.sh --check   # just print versions
#
# What kali-linux-default ALREADY ships:
#   burpsuite, owasp-zap, sqlmap, nikto, wpscan, dirb, dirbuster,
#   gobuster, hydra, hashcat, wfuzz, whatweb, wafw00f, nmap, masscan
#
# What this script adds (ProjectDiscovery + curated webapp/API toolkit):
#   nuclei + nuclei-templates, httpx, subfinder, katana, dnsx, naabu,
#   ffuf (if missing), feroxbuster, amass, dalfox, gau, waybackurls,
#   assetfinder, hakrawler, arjun, paramspider, LinkFinder, SecretFinder,
#   xsstrike, commix, jaeles, gf + gf-patterns, osmedeus,
#   mitmproxy, hurl, httpie, jq, postman-cli (newman), swagger-cli
#
# Storage: ~/Tools/ for source clones, ~/go/bin for Go binaries
# (added to PATH via /etc/profile.d/cwr-webapp.sh).

set -euo pipefail

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; RST='\033[0m'; BLD='\033[1m'
ok()   { echo -e "${GRN}[+]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
err()  { echo -e "${RED}[x]${RST} $*"; }

[[ $EUID -eq 0 ]] || { err "Run as root: sudo bash $0"; exit 1; }

# The "real" user (the one who owns ~ that tools land in). On Kali via
# Guacamole this is whoever sudo'd up — usually `ranger` for terra-range.
TARGET_USER="${SUDO_USER:-${TARGET_USER:-ranger}}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || {
  err "Cannot resolve home for user $TARGET_USER"; exit 1;
}
TOOLS_DIR="$TARGET_HOME/Tools"
GOBIN="$TARGET_HOME/go/bin"
LOG=/var/log/install-webapp-tools.log
exec > >(tee -a "$LOG") 2>&1
echo -e "\n${BLD}==== install-webapp-tools — $(date -Iseconds) ====${RST}"
ok "Target user: $TARGET_USER ($TARGET_HOME)"

# ---- --check short-circuit -----------------------------------------------
if [[ "${1:-}" == "--check" ]]; then
  printed=0
  for cmd in nuclei httpx subfinder katana dnsx naabu ffuf feroxbuster \
             amass dalfox gau waybackurls assetfinder hakrawler arjun \
             commix jaeles gf osmedeus mitmproxy hurl http newman \
             swagger-cli; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ver=$("$cmd" --version 2>/dev/null | head -1 || echo "?")
      printf "%-15s %s\n" "$cmd" "$ver"
      printed=1
    fi
  done
  [[ $printed -eq 1 ]] || warn "No webapp tools detected"
  exit 0
fi

# ---- 0. dpkg lock wait ----------------------------------------------------
# Kali's unattended-upgrades + the kali Ansible role can both hold the
# apt lock. Wait up to 15 min before bailing.
for i in $(seq 1 180); do
  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# ---- 1. apt-side tools ----------------------------------------------------
ok "APT update"
apt-get update -qq

ok "APT install: webapp + API tooling"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  golang-go git curl wget jq python3-pip pipx \
  ffuf feroxbuster amass nuclei subfinder httpx-toolkit naabu-toolkit \
  dnsx katana mitmproxy hurl httpie commix \
  npm \
  libpcap-dev build-essential \
  2>/dev/null || warn "Some apt packages may not exist on this release — falling back to Go installs"

# ---- 2. Go environment for $TARGET_USER -----------------------------------
ok "Go environment for $TARGET_USER"
sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/go/bin" "$TOOLS_DIR"
cat > /etc/profile.d/cwr-webapp.sh <<'EOF'
# Added by install-webapp-tools.sh — adds Go-installed pentest tools to PATH.
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"

# Safe-default rate-limit env vars. Per-invocation -rl / -c / --rate flags
# override these; the env values just stop a forgotten flag from
# sending 150 rps at a client target.
export NUCLEI_RPS=30
export NUCLEI_CONCURRENCY=25
export NUCLEI_BULK_SIZE=10
export HTTPX_RATE_LIMIT=50
export HTTPX_THREADS=25
export FFUF_RATE=30
export FFUF_THREADS=25
export FEROX_RATE=30
export NEWMAN_DELAY_MS=200

# Convenience aliases that bake the rate limits into the most-abused
# tools. Use the -safe variant for client work, the bare command for
# self-owned lab targets you've cleared for full speed.
alias nuclei-safe='nuclei -rl 30 -c 25 -bs 10 -timeout 10 -retries 1 -mhe 20 -stats'
alias httpx-safe='httpx -rate-limit 50 -threads 25 -timeout 10'
alias ffuf-safe='ffuf -rate 30 -t 25 -timeout 10'
alias feroxbuster-safe='feroxbuster --rate-limit 30 -t 10 --time-limit 1h'
alias newman-safe='newman run --delay-request 200'
# sqlmap defaults are SAFE for level 1 / risk 1 (no DoS-style payloads
# at level 1). The alias enforces that — operators can drop the alias
# and use sqlmap directly if they've explicitly cleared higher risk.
alias sqlmap-safe='sqlmap --batch --level 1 --risk 1 --threads 5 --delay 0.3'
EOF
chmod 644 /etc/profile.d/cwr-webapp.sh
export GOPATH="$TARGET_HOME/go"
export PATH="$PATH:$GOPATH/bin:/usr/local/go/bin"

go_install_as_user() {
  # $1 = pkg path (e.g. github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest)
  local pkg="$1"
  sudo -u "$TARGET_USER" \
    HOME="$TARGET_HOME" GOPATH="$TARGET_HOME/go" PATH="$PATH" \
    go install "$pkg" 2>&1 | tail -5 || warn "go install $pkg failed (continuing)"
}

# ---- 3. ProjectDiscovery toolkit (Go) -------------------------------------
# Most of these are also in Kali apt now, but Go-installs grab the latest
# release which moves faster than the Kali package mirror. Skipped if the
# binary is already on PATH from the apt step above.
ok "ProjectDiscovery toolkit (Go fallback)"
for tool in \
  "nuclei|github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" \
  "httpx|github.com/projectdiscovery/httpx/cmd/httpx@latest" \
  "subfinder|github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" \
  "katana|github.com/projectdiscovery/katana/cmd/katana@latest" \
  "dnsx|github.com/projectdiscovery/dnsx/cmd/dnsx@latest" \
  "naabu|github.com/projectdiscovery/naabu/v2/cmd/naabu@latest" \
  "interactsh-client|github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest"; do
  name="${tool%%|*}"; path="${tool#*|}"
  if command -v "$name" >/dev/null 2>&1; then
    ok "$name already present — skipping Go install"
  else
    go_install_as_user "$path"
  fi
done

# ---- 4. Other webapp Go tools ---------------------------------------------
ok "Curated Go webapp toolkit"
for tool in \
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
  command -v "$name" >/dev/null 2>&1 || go_install_as_user "$path"
done

# gf patterns library
if [[ ! -d "$TARGET_HOME/.gf" ]]; then
  sudo -u "$TARGET_USER" git clone --depth 1 \
    https://github.com/tomnomnom/gf "$TARGET_HOME/.gf-src" 2>/dev/null || true
  if [[ -d "$TARGET_HOME/.gf-src/examples" ]]; then
    sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.gf"
    sudo -u "$TARGET_USER" cp -r "$TARGET_HOME/.gf-src/examples/." "$TARGET_HOME/.gf/"
  fi
  sudo -u "$TARGET_USER" git clone --depth 1 \
    https://github.com/1ndianl33t/Gf-Patterns "$TARGET_HOME/.gf-extra" 2>/dev/null || true
  if [[ -d "$TARGET_HOME/.gf-extra" ]]; then
    sudo -u "$TARGET_USER" cp "$TARGET_HOME"/.gf-extra/*.json "$TARGET_HOME/.gf/" 2>/dev/null || true
  fi
fi

# ---- 5. Python tools via pipx (isolated venvs) ----------------------------
ok "Python tools via pipx"
sudo -u "$TARGET_USER" \
  HOME="$TARGET_HOME" PATH="$TARGET_HOME/.local/bin:$PATH" \
  bash -c '
    pipx ensurepath >/dev/null 2>&1 || true
    for pkg in arjun xsstrike paramspider; do
      if ! pipx list 2>/dev/null | grep -qi "$pkg"; then
        pipx install "$pkg" 2>/dev/null || pip install --user --break-system-packages "$pkg" 2>/dev/null || true
      fi
    done
  '

# ---- 6. LinkFinder + SecretFinder (clone-only, run via python3) -----------
ok "LinkFinder + SecretFinder"
for repo in \
  "LinkFinder|https://github.com/GerbenJavado/LinkFinder.git" \
  "SecretFinder|https://github.com/m4ll0k/SecretFinder.git"; do
  name="${repo%%|*}"; url="${repo#*|}"
  dest="$TOOLS_DIR/$name"
  if [[ ! -d "$dest" ]]; then
    sudo -u "$TARGET_USER" git clone --depth 1 "$url" "$dest" 2>/dev/null || warn "clone $name failed"
  fi
done

# ---- 7. Osmedeus -----------------------------------------------------------
# Osmedeus is a Go binary + workflows directory. The official installer
# fetches the release binary and pulls the default workflows from a
# separate repo (https://github.com/j3ssie/osmedeus-base).
ok "Osmedeus"
if ! sudo -u "$TARGET_USER" PATH="$GOBIN:$PATH" command -v osmedeus >/dev/null 2>&1; then
  go_install_as_user "github.com/j3ssie/osmedeus@latest"
fi
# Workflows: first run auto-fetches, but pre-pull so the first scan
# doesn't stall on a github clone.
if [[ ! -d "$TARGET_HOME/.osmedeus" ]]; then
  sudo -u "$TARGET_USER" HOME="$TARGET_HOME" PATH="$GOBIN:$PATH" \
    osmedeus update --vuln 2>&1 | tail -5 || \
    warn "osmedeus update --vuln failed; run interactively on first launch"
fi

# ---- 8. Nuclei templates ---------------------------------------------------
ok "Nuclei templates"
if command -v nuclei >/dev/null 2>&1; then
  sudo -u "$TARGET_USER" HOME="$TARGET_HOME" nuclei -ut -silent 2>&1 | tail -3 || \
    warn "nuclei -ut failed; retry manually post-install"
fi

# ---- 9. NPM-based API/Swagger tools ---------------------------------------
ok "API testing: newman (Postman CLI), swagger-cli"
npm install -g newman swagger-cli 2>&1 | tail -3 || warn "npm global install failed"

# ---- 10. Caido (modern Burp alternative) ----------------------------------
# Caido has both CLI and Desktop. Install the CLI as a foundation —
# the desktop GUI can be added by the consultant manually from
# https://caido.io/download if they prefer it over Burp.
ok "Caido CLI"
if ! command -v caido-cli >/dev/null 2>&1; then
  curl -fsSL https://caido.download/releases/install.sh \
    | TARGET_USER="$TARGET_USER" sh 2>&1 | tail -3 \
    || warn "Caido install failed (network policy?). Skipping."
fi

# ---- 11. Ownership pass ---------------------------------------------------
ok "Fixing ownership on $TOOLS_DIR + $TARGET_HOME/go + $TARGET_HOME/.osmedeus"
chown -R "$TARGET_USER:$TARGET_USER" \
  "$TOOLS_DIR" \
  "$TARGET_HOME/go" \
  "$TARGET_HOME/.osmedeus" 2>/dev/null || true
chown -R "$TARGET_USER:$TARGET_USER" \
  "$TARGET_HOME/.gf" "$TARGET_HOME/.gf-src" "$TARGET_HOME/.gf-extra" 2>/dev/null || true

# ---- 12. Tools/README.md --------------------------------------------------
cat > "$TOOLS_DIR/README.md" <<'EOF'
# Webapp / API consulting toolkit

Installed by `install-webapp-tools.sh`. PATH + safe-default env vars
live in `/etc/profile.d/cwr-webapp.sh` — `source` it or re-login if
Go-installed tools aren't on `$PATH` yet.

## SAFETY — read this before scanning a client

Client-target work uses the `-safe` aliases (defined in
`/etc/profile.d/cwr-webapp.sh`). They bake conservative rate limits
into the most-abused tools so a forgotten flag doesn't burn through
a customer's WAF budget or trip their rate-limiter as DoS:

| Alias                  | Rate          | Notes                                  |
| ---------------------- | ------------- | -------------------------------------- |
| `nuclei-safe`          | 30 rps        | -rl 30 -c 25 -bs 10 -mhe 20            |
| `httpx-safe`           | 50 rps        | probes only                            |
| `ffuf-safe`            | 30 rps        | -t 25 -timeout 10                      |
| `feroxbuster-safe`     | 30 rps        | --time-limit 1h                        |
| `newman-safe`          | 200ms delay   | smooths Postman bursts                 |
| `sqlmap-safe`          | risk 1 level 1| --threads 5 --delay 0.3                |

Run the bare command (no `-safe`) only against lab / self-owned
targets where you've cleared full-speed scanning in writing. Default
upstream rates (nuclei 150 rps etc.) will trip most production WAFs
and may be treated as DoS by the client.

If you're running heavier scans, prefer pointing them at the dedicated
`scanner` box — its wrappers (`runscan-quick`, `runscan-full`,
`runscan-api`) enforce both rate limits AND a scope file at
`/srv/scans/scope.txt`, so out-of-scope hosts are rejected before any
packet leaves the VM.

## Quick reference

### Recon / discovery
- `subfinder -d <domain>`                — passive subdomain enum
- `assetfinder --subs-only <domain>`     — second-source subdomain enum
- `amass enum -passive -d <domain>`      — heavier subdomain enum
- `httpx -l hosts.txt -title -tech-detect -sc`
- `katana -u https://target -d 3 -jc`    — JS-aware crawler
- `gau <domain>` / `waybackurls <domain>`— historical URLs from CommonCrawl/WB
- `arjun -u https://target/api/`         — hidden HTTP parameter discovery

### Active scanning
- `nuclei -u <target> -severity critical,high,medium`
- `nuclei -l hosts.txt -tags cve,oast -es info`
- `dalfox url <target>` / `dalfox pipe`  — XSS scanner
- `sqlmap -u <target> --batch --risk 3 --level 5`
- `nikto -h <target>` / `wpscan --url <target>`
- `feroxbuster -u <target> -w /usr/share/seclists/Discovery/Web-Content/raft-large-words.txt`
- `ffuf -u https://target/FUZZ -w wordlist`

### API testing
- `newman run collection.json`            — Postman CLI runner
- `swagger-cli validate openapi.json`
- `mitmproxy` / `mitmweb`                 — intercept + replay
- `hurl --test tests/*.hurl`              — declarative HTTP testing
- `http POST :8080/login user=x pw=y`     — quick HTTPie probe

### Frameworks
- `osmedeus scan -f general -t <target>`  — full automated assessment
  (workflows in ~/.osmedeus/core/workflow/)
- `jaeles scan -s '/path/to/signatures' -u <target>`

### JS analysis
- `python3 ~/Tools/LinkFinder/linkfinder.py -i https://target/static/app.js -o cli`
- `python3 ~/Tools/SecretFinder/SecretFinder.py -i https://target -o cli`

### Pattern grep (gf)
- `gau example.com | gf xss`              — common XSS sinks
- `gau example.com | gf sqli`             — possible SQLi params
- `gf -list`                              — every loaded pattern

## Already on the box (kali-linux-default)
Burp Suite Community, OWASP ZAP, sqlmap, nikto, wpscan, gobuster,
hydra, hashcat, wfuzz, whatweb, wafw00f, nmap, masscan.

## Log
Full install log: /var/log/install-webapp-tools.log
EOF
chown "$TARGET_USER:$TARGET_USER" "$TOOLS_DIR/README.md"

ok "Done."
echo
echo "Re-login (or 'source /etc/profile.d/cwr-webapp.sh') to pick up the"
echo "Go binaries on PATH. Re-run with --check to verify:"
echo "    sudo bash $0 --check"
