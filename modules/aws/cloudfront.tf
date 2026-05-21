################################################################################
# CloudFront fronting — AWS equivalent of modules/azure/frontdoor.tf.
#
# What this does (when advanced_c2.enabled and var.advanced_c2.domain are set):
#   - One CloudFront distribution per c2-redirector machine. Each has:
#       - origin = the redirector's public Elastic IP (port 443 over HTTPS)
#       - alias  = <redirector_subdomain>.<advanced_c2.domain>
#                  e.g.  redir-student-01-server.Authrix.com
#       - cert   = ACM-issued public cert (DNS-01 validated against the
#                  Route 53 zone for <advanced_c2.domain>)
#       - WAF    = none (Tier-2 — could add a custom rule that enforces
#                  the X-Api-* header pool just like AFD's fdid_header_required).
#
# Why CloudFront over Route 53 alias and not just a Route 53 A record
# pointing at the redirector EIP:
#   - The hostname presented to the implant is Authrix.com (the cover
#     domain). That hostname's TLS cert must be valid → we need a real
#     CA-signed cert for *.Authrix.com. CloudFront issues + serves that
#     for free; alternatives (running certbot on each redirector with
#     DNS-01) work too but require per-redirector lifecycle plumbing.
#   - CloudFront's edge POPs hide the redirector's actual IP, which is
#     the operational reason c2-redirector fronting exists in the first
#     place.
#
# fdid_header_required: when set, CloudFront forwards a custom header
# `X-Forwarded-CloudFront-Id` to the origin and the redirector's nginx
# config validates it (same role as AFD's X-Azure-FDID). The
# c2-redirector userdata already supports this — see redirector.sh.
################################################################################

data "aws_route53_zone" "advanced_c2" {
  count = local.cf_enabled ? 1 : 0
  name  = "${var.advanced_c2.domain}."
}

# ACM cert for *.<advanced_c2.domain> + apex. CloudFront cert lookups
# REQUIRE us-east-1 regardless of which region the rest of the stack
# deploys to. Use a provider alias so the rest of the module keeps
# using the operator-chosen region.
resource "aws_acm_certificate" "advanced_c2" {
  count             = local.cf_enabled ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = var.advanced_c2.domain
  subject_alternative_names = ["*.${var.advanced_c2.domain}"]
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
  tags = {
    Name  = "${var.range_name}-c2-cert"
    Range = var.range_name
  }
}

# DNS-01 validation records in Route 53.
resource "aws_route53_record" "advanced_c2_validation" {
  for_each = local.cf_enabled ? {
    for opt in aws_acm_certificate.advanced_c2[0].domain_validation_options :
    opt.domain_name => opt
  } : {}

  zone_id = data.aws_route53_zone.advanced_c2[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 60
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "advanced_c2" {
  count                   = local.cf_enabled ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.advanced_c2[0].arn
  validation_record_fqdns = [for r in aws_route53_record.advanced_c2_validation : r.fqdn]
}

# ============================================================================
# Per-redirector CloudFront distribution
# ============================================================================
locals {
  # Map: redirector machine name → student-id + fronted-stack. Same
  # shape as Azure's local.redirectors but built in one expression here.
  cf_redirectors = local.cf_enabled ? {
    for m in var.machines :
    m.name => m
    if m.role == "c2-redirector" && m.fronts != ""
  } : {}
}

# Each redirector needs its own public EIP — CloudFront origin must reach
# a stable public IP since the redirector is in a private subnet behind
# its own VPC IGW. (We could put redirectors directly in a public subnet
# and skip the EIP; this matches the Azure pattern where each redirector
# has a dedicated public IP for AFD origin reachability.)
resource "aws_eip" "redirector" {
  for_each = local.cf_redirectors
  domain   = "vpc"
  tags = {
    Name      = "${var.range_name}-${each.key}-eip"
    Range     = var.range_name
    StudentId = each.value.student_id
  }
}

resource "aws_eip_association" "redirector" {
  for_each             = local.cf_redirectors
  network_interface_id = aws_network_interface.linux[each.key].id
  allocation_id        = aws_eip.redirector[each.key].id
}

resource "aws_cloudfront_distribution" "redirector" {
  for_each = local.cf_redirectors
  enabled  = true
  aliases  = ["${local.redirector_subdomain[each.key]}.${var.advanced_c2.domain}"]

  origin {
    domain_name = aws_eip.redirector[each.key].public_ip
    origin_id   = "redirector-${each.key}"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    # When fdid_header_required, send a per-distribution custom header
    # the redirector's nginx can match on to drop direct-to-EIP probing.
    dynamic "custom_header" {
      for_each = var.advanced_c2.fdid_header_required ? [1] : []
      content {
        name  = "X-Forwarded-CloudFront-Id"
        value = each.key  # unique per redirector — burnable like AFD's FDID
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "redirector-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    # CloudFront's "AllViewer" managed origin-request policy forwards
    # headers + cookies + query strings 1:1 — what beacon traffic needs.
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # Managed-AllViewer
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.advanced_c2[0].arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  price_class = "PriceClass_100"  # NA + EU only — cheaper, fine for labs

  depends_on = [aws_acm_certificate_validation.advanced_c2]

  tags = {
    Name      = "${var.range_name}-${each.key}-cf"
    Range     = var.range_name
    StudentId = each.value.student_id
    Role      = "cloudfront"
  }
}

# Route 53 alias records — one A-ALIAS per redirector pointing at its
# CloudFront distribution.
resource "aws_route53_record" "redirector" {
  for_each = local.cf_redirectors
  zone_id  = data.aws_route53_zone.advanced_c2[0].zone_id
  name     = "${local.redirector_subdomain[each.key]}.${var.advanced_c2.domain}"
  type     = "A"
  alias {
    name                   = aws_cloudfront_distribution.redirector[each.key].domain_name
    zone_id                = aws_cloudfront_distribution.redirector[each.key].hosted_zone_id
    evaluate_target_health = false
  }
}

# ============================================================================
# Guacamole custom-hostname DNS record (separate from advanced_c2 zone).
# When services.guacamole.dns_zone_name is set, look up the zone and
# write an A record for <custom_hostname>.<dns_zone_name> → Guac EIP.
# This is the same pattern as Azure's guacamole_dns.tf.
# ============================================================================
data "aws_route53_zone" "guacamole" {
  count = local.guac_custom_enabled ? 1 : 0
  name  = "${var.services.guacamole.dns_zone_name}."
}

resource "aws_route53_record" "guacamole" {
  count   = local.guac_custom_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.guacamole[0].zone_id
  name    = "${var.services.guacamole.custom_hostname}.${var.services.guacamole.dns_zone_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.guacamole[0].public_ip]
}
