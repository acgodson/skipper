# The apex and www on one certificate, validated by DNS the owner adds at the registrar.
#
# Two applies, by design, because nothing here creates DNS:
#
#   terraform apply -target=aws_acm_certificate.site
#   terraform output acm_validation_records      # hand these to the owner
#   terraform apply                              # waits for ISSUED, then builds the rest
resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name               = local.web_domain
  subject_alternative_names = [local.www_domain]
  validation_method         = "DNS"

  tags = { Name = local.name }

  lifecycle {
    create_before_destroy = true
  }
}

# No DNS provider, so this resource only waits: the FQDNs are the certificate's own, and
# issuance happens once the records resolve. Without it the distribution would be created
# against a certificate that is still PENDING_VALIDATION, which CloudFront refuses.
resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for option in aws_acm_certificate.site.domain_validation_options : option.resource_record_name]

  timeouts {
    create = var.certificate_issue_timeout
  }
}
