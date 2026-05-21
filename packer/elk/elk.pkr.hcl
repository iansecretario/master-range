################################################################################
# Packer template: ELK stack (Elastic + Kibana + Logstash) pre-baked on
# Debian 12 for the terra-range "elk" role.
#
# Bakes in:
#   - Elastic 8.x repo + Elasticsearch + Kibana + Logstash apt packages
#   - Java prerequisites (bundled with Elastic but pinning ensures
#     downstream userdata doesn't accidentally pull a different JRE)
#   - filebeat + winlogbeat agent packages staged in /opt/beat-pkgs/
#     so deployed beat installs (on c2 boxes, DC, etc.) can pull from
#     the ELK host instead of going to elastic.co — saves egress in
#     locked-down ranges
#   - Services installed but NOT enabled — deploy-time userdata sets
#     the actual cluster name, network.host, elastic password, and
#     enables them. Pre-baking the INSTALL alone saves ~10-15 min of
#     apt churn per ELK first-boot.
#
# What stays at deploy time:
#   - elasticsearch.yml + kibana.yml customization (cluster id, bind IP,
#     password from random_password)
#   - Elastic password bootstrap (elasticsearch-setup-passwords)
#   - Service enable + start
#   - Initial index template + dashboard imports
#
# Time saved per deploy: ~12-15 min on the ELK box.
#
# Usage:
#   ./range bake elk     # one-time, ~25-30 min
################################################################################

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
  }
}

variable "azure_subscription_id" { type = string }
variable "sig_resource_group"    { type = string }
variable "sig_name"              { type = string }
variable "azure_region" {
  type    = string
  default = "southeastasia"
}
variable "image_definition" {
  type    = string
  default = "elk"
}
variable "image_version" {
  type    = string
  default = "1.0.0"
}
variable "vm_size" {
  # ELK install + Kibana + Logstash idle is comfortable on a 4-vCPU
  # box. The deployed VM is bigger (D8s_v5 in some scenarios); the bake
  # only needs enough headroom for apt + the agent staging.
  type    = string
  default = "Standard_D4s_v5"
}

source "azure-arm" "elk" {
  use_azure_cli_auth = true
  subscription_id    = var.azure_subscription_id

  image_publisher = "Debian"
  image_offer     = "debian-12"
  image_sku       = "12-gen2"
  image_version   = "latest"

  os_type         = "Linux"
  vm_size         = var.vm_size
  location        = var.azure_region
  # 64 GB build disk so the apt unpack + agent package cache has room.
  # Deployed VMs get their own (larger) disk via vms.tf.
  os_disk_size_gb = 64

  communicator = "ssh"
  ssh_username = "packer"
  ssh_timeout  = "20m"

  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.sig_resource_group
    gallery_name         = var.sig_name
    image_name           = var.image_definition
    image_version        = var.image_version
    replication_regions  = [var.azure_region]
    storage_account_type = "Standard_LRS"
  }

  managed_image_name                = "${var.image_definition}-${var.image_version}-tmp"
  managed_image_resource_group_name = var.sig_resource_group
}

build {
  sources = ["source.azure-arm.elk"]

  # Step 1: install Elastic + Kibana + Logstash + agents.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/scripts/elk-baseline.sh"
    timeout         = "30m"
  }

  # Step 2: deprovision.
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script          = "${path.root}/../_shared/scripts/linux-deprovision.sh"
  }
}
