# AWS module — pending

The AWS provider for this range is **not implemented yet**. Azure is
the priority. This directory exists so the project layout is symmetric
and so the generator can already write `envs/aws/terraform.tfvars.json`.

When implemented, this module will mirror the Azure one:

| Azure                                | AWS equivalent                                 |
| ------------------------------------ | ---------------------------------------------- |
| Hub VNet + spoke VNets + peering     | Hub VPC + spoke VPCs + Transit Gateway         |
| `azurerm_subnet`                     | `aws_subnet`                                   |
| `azurerm_network_security_group`     | `aws_security_group` + NACLs                   |
| `azurerm_nat_gateway` (toggle)       | `aws_nat_gateway` + route-table toggle         |
| `azurerm_linux_virtual_machine`      | `aws_instance` (Ubuntu/Debian/Kali AMIs)       |
| `azurerm_windows_virtual_machine`    | `aws_instance` with Windows AMI + `user_data`  |
| `CustomScriptExtension` / cloud-init | `user_data` for both (PowerShell-on-Windows works the same way via EC2Launch) |
| Marketplace `plan {}` for Kali       | Subscribed Marketplace AMI                     |
| Public IP for hub services           | EIP attached to ELK/Guacamole instances        |

Reused as-is across providers:

- `userdata/*.sh` (Linux: cloud-init payloads work identically on AWS)
- `userdata/windows-*.ps1` (delivered through `user_data` on AWS;
  Windows AMIs run it via EC2Launch v2)
- The Guacamole REST registration script (`register.py`)

To get started:

    # 1. Build the AWS module here, mirroring modules/azure/*
    # 2. Drop in modules/aws/userdata/ as a symlink/copy of modules/azure/userdata/
    # 3. Add envs/aws/main.tf calling module "range" { source = "../../modules/aws" }

The generator already emits `envs/aws/terraform.tfvars.json` when run
with `--provider aws`; the variable shape is provider-agnostic.
