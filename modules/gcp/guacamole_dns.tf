################################################################################
# Optional Cloud DNS managed-zone wiring for the operator-facing Guacamole
# custom hostname. Provider-port of modules/azure/guacamole_dns.tf.
#
# Phase A status: STUB. Only the `local.guac_effective_fqdn` consumer
# contract is satisfied here so outputs.tf passes validation. The full
# implementation (creating an A record in the operator's Cloud DNS zone +
# wiring it into the Guacamole VM's external IP + LE / Cloud-managed cert
# issuance) lands in Phase D alongside cdn.tf.
#
# When var.services.guacamole.dns_zone_name + custom_hostname are set,
# Phase D will:
#   - data.google_dns_managed_zone {zone in operator's DNS project}
#   - google_dns_record_set { A → google_compute_address.guacamole[0].address }
#   - google_compute_managed_ssl_certificate { subject = "<custom_hostname>.<dns_zone>" }
# and update guac_effective_fqdn to resolve to that custom FQDN.
################################################################################

locals {
  # Resolved FQDN for Guacamole. Null when no custom DNS is configured;
  # outputs.tf will fall back to the public IP literal in that case.
  guac_effective_fqdn = (
    try(var.services.guacamole.custom_hostname, "") != "" &&
    try(var.services.guacamole.dns_zone_name, "") != ""
    ? "${var.services.guacamole.custom_hostname}.${var.services.guacamole.dns_zone_name}"
    : null
  )
}
