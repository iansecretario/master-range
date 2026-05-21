################################################################################
# Outputs — what range applies need to find this shared Guac and register
# their connections into it.
################################################################################

output "guacamole_url" {
  description = "The HTTPS URL operators + students use to reach the shared Guacamole UI. Either the custom-domain hostname (https://guac.cyberwarrange.com) or the Azure-assigned cloudapp.azure.com FQDN."
  value       = "https://${local.effective_fqdn}"
}

output "guacamole_fqdn" {
  description = "Bare hostname (no scheme). For DNS lookups, cert validation, etc."
  value       = local.effective_fqdn
}

output "guacamole_admin_user" {
  description = "Admin username for the shared Guac (default 'guacadmin'). Used by range applies to authenticate to the REST API for connection registration (Phase 2B)."
  value       = var.admin_user
}

output "guacamole_admin_password" {
  description = "Admin password for the shared Guac. Either the operator-supplied value or the random_password generated at apply time."
  value       = local.effective_admin_password
  sensitive   = true
}

output "guacamole_public_ip" {
  description = "Static public IP of the Guac VM. Useful for adding to NSG allow-lists on peered VNets, DNS verification, etc."
  value       = azurerm_public_ip.guac.ip_address
}

output "guacamole_private_ip" {
  description = "Static private IP of the Guac VM (default 10.250.0.20). Range hosts in peered VNets reach Guac at this address for the back-channel."
  value       = var.static_ip
}

output "guacamole_vnet_id" {
  description = "Resource ID of the Guac's VNet. Required by range apply (Phase 2B): the range creates an azurerm_virtual_network_peering on its own hub VNet pointing at THIS vnet_id so Guac can reach the range's spoke private IPs."
  value       = azurerm_virtual_network.guac.id
}

output "guacamole_vnet_name" {
  description = "Name of the Guac's VNet. Some peering resources need name+RG; this exposes both for convenience."
  value       = azurerm_virtual_network.guac.name
}

output "guacamole_resource_group" {
  description = "Resource group containing every Guac resource. ./range guac status / ./range guac destroy operate on this RG."
  value       = azurerm_resource_group.guac.name
}

output "guacamole_subscription_id" {
  description = "Subscription ID containing the Guac. Range applies pass this to their peering resource (cross-sub peering needs both subs auth'd)."
  value       = data.azurerm_subscription.current.subscription_id
}
