#!/usr/bin/env bash
# refresh-geofence.sh — download per-country CIDR blocks for use in
# `guacamole_allow_countries:` (and any other geo-restricted ingress).
#
# Source: ipdeny.com aggregated zones. We pull the *aggregated* form
# (adjacent prefixes collapsed) so the resulting list fits inside an
# Azure NSG rule's `source_address_prefixes` 4000-entry limit.
#
# Usage:
#   ./scripts/refresh-geofence.sh                        # default 6 countries
#   ./scripts/refresh-geofence.sh SG AU                  # specific subset
#
# Output: one file per country at geofence/<CC>.txt — one CIDR per line,
# blank lines + comments stripped. Files are deliberately not committed
# (see geofence/.gitignore) — re-run this script when allocations
# change (RIRs publish weekly).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GEOFENCE_DIR="$REPO/geofence"
mkdir -p "$GEOFENCE_DIR"

# Default to the five the redteam-lab scenario uses. AU was originally
# in the list but its aggregated zone alone is ~5600 CIDRs — combined
# with the others it overflows the per-NSG-rule budget. Add AU back
# explicitly if you really need it: ./scripts/refresh-geofence.sh AU
if [[ "$#" -gt 0 ]]; then
  countries=("$@")
else
  countries=(SG PH AE QA SA)
fi

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*" >&2; }

bold "Refreshing geofence CIDRs from ipdeny.com (aggregated zones)"
total=0
for cc in "${countries[@]}"; do
  ccu=$(echo "$cc" | tr 'a-z' 'A-Z')
  ccl=$(echo "$cc" | tr 'A-Z' 'a-z')
  url="https://www.ipdeny.com/ipblocks/data/aggregated/${ccl}-aggregated.zone"
  out="$GEOFENCE_DIR/${ccu}.txt"

  if curl -fsSL --max-time 30 "$url" -o "$out.tmp"; then
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$out.tmp" > "$out" || true
    rm -f "$out.tmp"
    n=$(wc -l < "$out" | tr -d ' ')
    printf "  [+] %-3s  %5s CIDRs  → %s\n" "$ccu" "$n" "$out"
    total=$((total + n))
  else
    warn "  [!] $ccu: download failed (network? country code?)"
    rm -f "$out.tmp"
  fi
done

echo
bold "Total: $total CIDRs across ${#countries[@]} countries"
if (( total > 3500 )); then
  warn "WARNING: total exceeds Azure NSG 4000-entry rule limit. Consider"
  warn "         dropping a country or splitting into multiple NSG rules."
fi
