################################################################################
# Module outputs. Mirror of modules/azure/outputs.tf — same names so the
# env layer's outputs.tf can re-export them with no logic changes.
################################################################################

output "guacamole_url" {
  description = "Public URL of the Guacamole web UI."
  value = (
    var.services.guacamole.enabled
    ? "https://${local.guac_effective_fqdn}"
    : "guacamole disabled"
  )
}

output "guacamole_fqdn" {
  value = local.guac_effective_fqdn
}

output "guacamole_acme_email" {
  value = var.services.guacamole.acme_email
}

output "guacamole_admin_user" {
  value = var.services.guacamole.admin_user
}

output "guacamole_admin_password" {
  description = "Operator's Guacamole admin password."
  value       = local.effective_guacamole_admin_password
  sensitive   = true
}

output "elk_kibana_url" {
  description = "Public Kibana URL (when ELK has a public EIP)."
  value = (
    var.services.elk.enabled && var.services.elk.public_ip
    ? "http://${aws_eip.elk[0].public_ip}:5601"
    : "elk: internal-only (use Guacamole)"
  )
}

output "operator_ssh_private_key_path" {
  description = "Path to the auto-generated operator SSH private key."
  value       = local_sensitive_file.operator_private_key.filename
}

output "lab_dir" {
  description = "Per-deploy directory containing the SSH keypair and credentials.txt."
  value       = local.lab_dir
}

output "machine_ips" {
  description = "Map of machine name → private IP."
  value = merge(
    { for k, ni in aws_network_interface.linux   : k => ni.private_ip },
    { for k, ni in aws_network_interface.windows : k => ni.private_ip },
  )
}

output "advanced_c2" {
  description = "CloudFront fronting metadata (empty when advanced_c2.enabled=false)."
  value = local.cf_enabled ? {
    domain         = var.advanced_c2.domain
    distributions  = {
      for k, d in aws_cloudfront_distribution.redirector :
      k => {
        domain_name = d.domain_name
        aliases     = d.aliases
        cf_id_header = var.advanced_c2.fdid_header_required ? k : ""
      }
    }
    # Same keys as Azure's advanced_c2 output for inventory.py / scripts.
    profile_name  = "n/a-on-aws"
    endpoint_name = "n/a-on-aws"
  } : null
}

output "student_users" {
  description = "Per-student Guacamole logins (when services.guacamole.autoregister)."
  value       = var.student_users
}

output "range_name" {
  value = var.range_name
}

output "summary" {
  description = "One-line human-readable summary, like `range = redteam-lab, region = us-east-1, machines = 13`."
  value = format(
    "range = %s, region = %s, students = %d, machines = %d",
    var.range_name, var.region, var.students.count, length(var.machines)
  )
}
