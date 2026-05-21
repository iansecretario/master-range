# `geofence/` — per-country CIDR snapshots

Populated on demand by `scripts/refresh-geofence.sh`. One `<CC>.txt`
file per country, one CIDR per line. Source: IPdeny.com aggregated
zones.

Used by the generator when a scenario sets `guacamole_allow_countries:
[SG, AU, ...]` — those CIDRs get merged into `guacamole_ingress_cidrs`
at generation time, replacing the default `0.0.0.0/0`.

These files are gitignored (the data ages weekly as RIRs reallocate
prefixes; re-run the refresh script to update).
