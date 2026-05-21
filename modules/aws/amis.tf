################################################################################
# AMI lookups.
#
# Mirrors modules/azure/images.tf's `image_map` shape: a map keyed by the
# OS string the generator emits (ubuntu-22, kali, windows-server-2022, ...)
# whose value is an EC2-compatible AMI id.
#
# Strategy: for every OS we use a `data "aws_ami"` block with the most
# specific name filter we can write, plus `owners` to lock to the canonical
# publisher. `most_recent = true` so the freshest patched image always
# wins; lifecycle ignore in instance resources prevents AMI bumps from
# force-recreating running VMs.
#
# Kali requires accepting the AWS Marketplace EULA once per account
# (see https://aws.amazon.com/marketplace/pp/prodview-fznsw3f7mq7to).
# `./range accept-marketplace --aws` will be added in a follow-up; for
# now the operator subscribes manually before first apply.
################################################################################

# --- Ubuntu (Canonical) -----------------------------------------------------
data "aws_ami" "ubuntu_22" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "ubuntu_24" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# --- Debian -----------------------------------------------------------------
data "aws_ami" "debian_12" {
  most_recent = true
  owners      = ["136693071363"]  # Debian official
  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
}

# --- Kali (Marketplace) -----------------------------------------------------
# Offensive Security's published AMI. Requires marketplace subscription
# on the account first. AMI name pattern is "kali-last-snapshot-amd64-*".
data "aws_ami" "kali" {
  most_recent = true
  owners      = ["679593333241"]  # AWS Marketplace publisher (Offensive Security)
  filter {
    name   = "name"
    values = ["kali-last-snapshot-amd64-*"]
  }
}

# --- Windows Server (Microsoft) --------------------------------------------
data "aws_ami" "windows_server_2019" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2019-English-Full-Base-*"]
  }
}

data "aws_ami" "windows_server_2022" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

data "aws_ami" "windows_server_2025" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Full-Base-*"]
  }
}

# --- Windows Client AMIs ----------------------------------------------------
# AWS doesn't publish Windows 10/11 client AMIs in the standard catalog —
# they're available via WorkSpaces / Marketplace and require manual import
# for desktop use. For lab purposes we map "windows-10" and "windows-11"
# to Windows Server 2022 with Desktop Experience as a close-enough analog
# (Domain join + RDP + RSAT all work). Operators who need the actual
# desktop SKU can swap in a Bring-Your-Own-License AMI later.
locals {
  image_ami_id = {
    "ubuntu-22"           = data.aws_ami.ubuntu_22.id
    "ubuntu-24"           = data.aws_ami.ubuntu_24.id
    "debian-12"           = data.aws_ami.debian_12.id
    "kali"                = data.aws_ami.kali.id
    "kali-rolling"        = data.aws_ami.kali.id
    "windows-server-2019" = data.aws_ami.windows_server_2019.id
    "windows-server-2022" = data.aws_ami.windows_server_2022.id
    "windows-server-2025" = data.aws_ami.windows_server_2025.id
    # Client-OS aliases (see note above).
    "windows-10"          = data.aws_ami.windows_server_2022.id
    "windows-11"          = data.aws_ami.windows_server_2022.id
  }

  # Per-OS root volume size (GB). Windows AMIs need more headroom than
  # Linux — same defaults as Azure's disk_size_gb maps.
  image_root_size = {
    "ubuntu-22"           = 30
    "ubuntu-24"           = 30
    "debian-12"           = 30
    "kali"                = 80
    "kali-rolling"        = 80
    "windows-server-2019" = 128
    "windows-server-2022" = 128
    "windows-server-2025" = 128
    "windows-10"          = 128
    "windows-11"          = 128
  }

  # Per-OS default SSH user. Used by inventory.py + operator UX docs.
  image_ssh_user = {
    "ubuntu-22"    = "ubuntu"
    "ubuntu-24"    = "ubuntu"
    "debian-12"    = "admin"
    "kali"         = "kali"
    "kali-rolling" = "kali"
  }
}

# Map of scenario-emitted t-shirt sizes to EC2 instance types. Mirrors
# modules/azure/images.tf's size_map. The mapping is "near-equivalent
# vCPU + RAM"; exact billing parity isn't possible across clouds.
locals {
  size_map = {
    # Linux teamservers / Kali / target boxes
    "small"   = "t3.small"     # 2 vCPU / 2 GB
    "medium"  = "t3.medium"    # 2 vCPU / 4 GB
    "large"   = "t3.large"     # 2 vCPU / 8 GB
    "xlarge"  = "t3.xlarge"    # 4 vCPU / 16 GB
    "2xlarge" = "t3.2xlarge"   # 8 vCPU / 32 GB
    # Windows / heavier workloads
    "win-small"  = "t3.medium"
    "win-medium" = "t3.large"
    "win-large"  = "t3.xlarge"
    # Direct passthrough (an Azure Standard_D4s_v4 lookalike, for example)
    "Standard_B2ms"    = "t3.medium"
    "Standard_B4ms"    = "t3.xlarge"
    "Standard_D4s_v4"  = "t3.xlarge"
    "Standard_D8s_v4"  = "t3.2xlarge"
    "Standard_D4s_v5"  = "m5.xlarge"
    "Standard_D8s_v5"  = "m5.2xlarge"
  }
}
