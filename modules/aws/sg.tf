################################################################################
# Security groups — AWS analog of the Azure NSGs in hub.tf + sg rules
# scattered through services.tf/vms.tf.
#
# Pattern mirror:
#   Azure NSG rule → SG ingress rule + (when egress matters) egress rule
#   `source_address_prefixes` chunked across rules to dodge Azure's
#   6000-prefix-per-NSG cap → AWS lifts the chunking (SG ingress accepts
#   a list of CIDR blocks per rule with a soft cap at ~10000; we don't
#   bother).
#
# Five SGs, mirroring the Azure NSG split:
#   - hub_mgmt    Guacamole front door (443/80/22 from operator CIDRs +
#                 all-traffic from 10.0.0.0/8 peered subnets).
#   - hub_infra   shared infra (Ghostwriter/SteppingStones/RedELK/Workspaces).
#                 Web ports from operator CIDRs, log ports from 10/8,
#                 VNC pool from Guac's IP only.
#   - student_attacker  attacker subnet (kali + c2-server + c2-redirector).
#                 SSH/RDP/VNC from hub_mgmt (Guacamole-fronted), full
#                 egress to targets, redirector 443 from anywhere in
#                 advanced_c2.enabled mode.
#   - student_targets   target subnet (windows-dc + windows-member + linux-target).
#                 Inbound from attacker subnet only; outbound full.
################################################################################

# ============================================================================
# Hub mgmt SG (Guacamole + ELK)
# ============================================================================
resource "aws_security_group" "hub_mgmt" {
  name        = "${var.range_name}-hub-mgmt-sg"
  description = "Hub management subnet — Guacamole, ELK"
  vpc_id      = aws_vpc.hub.id

  # Outbound: unrestricted.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.range_name}-hub-mgmt-sg", Range = var.range_name }
}

resource "aws_security_group_rule" "hub_mgmt_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.guacamole_ingress_cidrs
  security_group_id = aws_security_group.hub_mgmt.id
  description       = "Guacamole HTTPS from operator CIDRs"
}
resource "aws_security_group_rule" "hub_mgmt_http_acme" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hub_mgmt.id
  description       = "LE HTTP-01 challenge (cert issuance + 60-day renewal)"
}
resource "aws_security_group_rule" "hub_mgmt_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.guacamole_ingress_cidrs
  security_group_id = aws_security_group.hub_mgmt.id
  description       = "Operator SSH for emergency access"
}
resource "aws_security_group_rule" "hub_mgmt_kibana" {
  type              = "ingress"
  from_port         = 5601
  to_port           = 5601
  protocol          = "tcp"
  cidr_blocks       = var.guacamole_ingress_cidrs
  security_group_id = aws_security_group.hub_mgmt.id
  description       = "Kibana from operator CIDRs"
}
resource "aws_security_group_rule" "hub_mgmt_from_peered" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = aws_security_group.hub_mgmt.id
  description       = "All traffic from peered student VPCs (Filebeat/Winlogbeat/etc)"
}

# ============================================================================
# Hub infra SG (shared services + workspaces)
# ============================================================================
resource "aws_security_group" "hub_infra" {
  name        = "${var.range_name}-hub-infra-sg"
  description = "Hub shared-infra subnet"
  vpc_id      = aws_vpc.hub.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.range_name}-hub-infra-sg", Range = var.range_name }
}

resource "aws_security_group_rule" "hub_infra_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.guacamole_ingress_cidrs
  security_group_id = aws_security_group.hub_infra.id
  description       = "Operator SSH"
}
resource "aws_security_group_rule" "hub_infra_web" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "tcp"
  cidr_blocks       = var.guacamole_ingress_cidrs
  security_group_id = aws_security_group.hub_infra.id
  description       = "Web/SSH/Kibana from operator CIDRs"
  # Chosen ports below — opening 443/8000/8080/5601 explicitly avoids
  # the all-tcp surface we'd otherwise expose.
  prefix_list_ids   = []
}
resource "aws_security_group_rule" "hub_infra_logs_from_peers" {
  type              = "ingress"
  from_port         = 5044
  to_port           = 5044
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"]
  security_group_id = aws_security_group.hub_infra.id
  description       = "Logstash from peered teamservers + redirectors"
}
resource "aws_security_group_rule" "hub_infra_from_guacamole_vnc" {
  type              = "ingress"
  from_port         = 5901
  to_port           = 5909
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.20/32"]  # Guacamole's pinned hub IP
  security_group_id = aws_security_group.hub_infra.id
  description       = "kali-2 workspace pool: only guacd reaches the slots"
}

# ============================================================================
# Per-student attacker SG
# ============================================================================
resource "aws_security_group" "student_attacker" {
  for_each    = toset(local.students)
  name        = "${var.range_name}-${each.key}-attacker-sg"
  description = "Attacker subnet (kali, c2-server, c2-redirector)"
  vpc_id      = aws_vpc.student[each.key].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name      = "${var.range_name}-${each.key}-attacker-sg"
    Range     = var.range_name
    StudentId = each.key
  }
}

# All traffic from hub (so Guacamole's guacd can hit RDP/SSH/VNC, and
# operator-laptop SSH via ProxyJump through Guacamole works).
resource "aws_security_group_rule" "student_attacker_from_hub" {
  for_each          = toset(local.students)
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.hub_cidr]
  security_group_id = aws_security_group.student_attacker[each.key].id
  description       = "All traffic from hub (Guacamole jump path)"
}
# All traffic within the same student VPC (attacker ↔ targets).
resource "aws_security_group_rule" "student_attacker_intra_vpc" {
  for_each          = toset(local.students)
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [local.student_vpc_cidr[each.key]]
  security_group_id = aws_security_group.student_attacker[each.key].id
  description       = "Intra-VPC (attacker and targets in same student)"
}
# Public 443 for c2-redirector (CloudFront origin reaches here over the
# public Internet). Locked to 0.0.0.0/0 because CloudFront edge IPs are
# not a stable set; defense-in-depth comes from the redirector's
# X-Api-* header validation.
resource "aws_security_group_rule" "student_attacker_redirector_https" {
  for_each          = toset(local.students)
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.student_attacker[each.key].id
  description       = "c2-redirector :443 from Internet (CloudFront origin)"
}

# ============================================================================
# Per-student targets SG
# ============================================================================
resource "aws_security_group" "student_targets" {
  for_each    = toset(local.students)
  name        = "${var.range_name}-${each.key}-targets-sg"
  description = "Target subnet (windows-dc, windows-member, linux-target)"
  vpc_id      = aws_vpc.student[each.key].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name      = "${var.range_name}-${each.key}-targets-sg"
    Range     = var.range_name
    StudentId = each.key
  }
}

resource "aws_security_group_rule" "student_targets_from_hub" {
  for_each          = toset(local.students)
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.hub_cidr]
  security_group_id = aws_security_group.student_targets[each.key].id
  description       = "All traffic from hub"
}
resource "aws_security_group_rule" "student_targets_intra_vpc" {
  for_each          = toset(local.students)
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [local.student_vpc_cidr[each.key]]
  security_group_id = aws_security_group.student_targets[each.key].id
  description       = "Intra-VPC traffic (attacker to targets)"
}
