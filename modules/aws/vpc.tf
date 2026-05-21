################################################################################
# VPC topology — AWS analog of modules/azure/hub.tf + vms.tf VNet plumbing.
#
# Topology:
#   - Hub VPC (10.0.0.0/22)
#       - hub-mgmt    subnet 10.0.0.0/24   (Guacamole + ELK live here)
#       - hub-infra   subnet 10.0.1.0/24   (RedELK / Ghostwriter / SteppingStones / workspaces)
#   - Per-student VPC (10.<n>.0.0/22 where n = student_index + 1)
#       - targets     subnet 10.<n>.0.0/24
#       - attacker    subnet 10.<n>.1.0/24
#   - Hub <-> Student VPC peering, fully connected (auto-accept on both sides).
#
# Why one VPC per student instead of one big shared VPC:
#   - Mirrors the Azure layout exactly (hub VNet + spoke VNets).
#   - Lets `students.tenancy = isolated` work: each student's targets are
#     in their own IPv4 plan, no chance of CIDR overlap, and you can
#     attach per-VPC security boundaries without juggling subnet ACLs.
#   - Trade-off: AWS caps default at 5 VPCs/region. Operators running
#     more than 5 students must raise the quota or switch to shared-tenancy
#     (one VPC, students separated by subnet) — TODO for a later pass.
#
# IGW + NAT:
#   - Hub has an IGW (Guacamole needs a public IP, ELK can have one).
#   - Each student VPC has its own IGW (used by attacker subnet for
#     outbound tool installs / C2 callouts / persona browsing). Target
#     VMs reach Internet via the same IGW; lockdown=true seals this by
#     removing the 0.0.0.0/0 route at the route-table level.
################################################################################

# ============================================================================
# Hub VPC
# ============================================================================
resource "aws_vpc" "hub" {
  cidr_block           = var.hub_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name  = "${var.range_name}-hub-vpc"
    Range = var.range_name
    Tier  = "hub"
  }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.range_name}-hub-igw", Range = var.range_name }
}

# Pick an AZ deterministically — first available in the region. Multi-AZ
# is overkill for a lab range; if you need it, switch to a `for_each`
# over `data.aws_availability_zones.available.names`.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  primary_az = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "hub_mgmt" {
  vpc_id                  = aws_vpc.hub.id
  cidr_block              = var.hub_mgmt_cidr
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false  # we attach EIPs explicitly to hub services
  tags = {
    Name  = "${var.range_name}-hub-mgmt"
    Range = var.range_name
    Tier  = "hub-mgmt"
  }
}

resource "aws_subnet" "hub_infra" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_infra_cidr
  availability_zone = local.primary_az
  tags = {
    Name  = "${var.range_name}-hub-infra"
    Range = var.range_name
    Tier  = "hub-infra"
  }
}

resource "aws_route_table" "hub" {
  vpc_id = aws_vpc.hub.id
  # IGW egress is conditional on lockdown=false. lockdown=true strips
  # this rule so the entire hub becomes internal-only.
  dynamic "route" {
    for_each = var.lockdown ? [] : [1]
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.hub.id
    }
  }
  # Routes to every peered student VPC are added dynamically below via
  # aws_route resources (count-based — easier than dynamic blocks here).
  tags = { Name = "${var.range_name}-hub-rt", Range = var.range_name }
}

resource "aws_route_table_association" "hub_mgmt" {
  subnet_id      = aws_subnet.hub_mgmt.id
  route_table_id = aws_route_table.hub.id
}
resource "aws_route_table_association" "hub_infra" {
  subnet_id      = aws_subnet.hub_infra.id
  route_table_id = aws_route_table.hub.id
}

# ============================================================================
# Per-student VPCs
# ============================================================================
resource "aws_vpc" "student" {
  for_each             = toset(local.students)
  cidr_block           = local.student_vpc_cidr[each.key]
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name      = "${var.range_name}-student-${each.key}-vpc"
    Range     = var.range_name
    StudentId = each.key
  }
}

resource "aws_internet_gateway" "student" {
  for_each = toset(local.students)
  vpc_id   = aws_vpc.student[each.key].id
  tags     = { Name = "${var.range_name}-student-${each.key}-igw", Range = var.range_name }
}

resource "aws_subnet" "student_targets" {
  for_each                = toset(local.students)
  vpc_id                  = aws_vpc.student[each.key].id
  cidr_block              = local.student_targets_cidr[each.key]
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false
  tags = {
    Name      = "${var.range_name}-${each.key}-targets"
    Range     = var.range_name
    StudentId = each.key
    Tier      = "targets"
  }
}

resource "aws_subnet" "student_attacker" {
  for_each                = toset(local.students)
  vpc_id                  = aws_vpc.student[each.key].id
  cidr_block              = local.student_attacker_cidr[each.key]
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false
  tags = {
    Name      = "${var.range_name}-${each.key}-attacker"
    Range     = var.range_name
    StudentId = each.key
    Tier      = "attacker"
  }
}

resource "aws_route_table" "student" {
  for_each = toset(local.students)
  vpc_id   = aws_vpc.student[each.key].id
  dynamic "route" {
    for_each = var.lockdown ? [] : [1]
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.student[each.key].id
    }
  }
  tags = { Name = "${var.range_name}-${each.key}-rt", Range = var.range_name }
}

resource "aws_route_table_association" "student_targets" {
  for_each       = toset(local.students)
  subnet_id      = aws_subnet.student_targets[each.key].id
  route_table_id = aws_route_table.student[each.key].id
}
resource "aws_route_table_association" "student_attacker" {
  for_each       = toset(local.students)
  subnet_id      = aws_subnet.student_attacker[each.key].id
  route_table_id = aws_route_table.student[each.key].id
}

# ============================================================================
# Hub ↔ Student VPC peering
# ============================================================================
resource "aws_vpc_peering_connection" "hub_to_student" {
  for_each    = toset(local.students)
  vpc_id      = aws_vpc.hub.id
  peer_vpc_id = aws_vpc.student[each.key].id
  auto_accept = true  # same account, no cross-acct handshake needed
  tags = {
    Name      = "${var.range_name}-hub-${each.key}-peer"
    Range     = var.range_name
    StudentId = each.key
  }
}

# Hub route table: one route per peered student VPC.
resource "aws_route" "hub_to_student" {
  for_each                  = toset(local.students)
  route_table_id            = aws_route_table.hub.id
  destination_cidr_block    = local.student_vpc_cidr[each.key]
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_student[each.key].id
}

# Student route tables: one route back to the hub.
resource "aws_route" "student_to_hub" {
  for_each                  = toset(local.students)
  route_table_id            = aws_route_table.student[each.key].id
  destination_cidr_block    = var.hub_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_student[each.key].id
}
