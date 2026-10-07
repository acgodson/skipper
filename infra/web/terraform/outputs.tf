# The records the owner adds at the registrar before the certificate can be issued. Read
# this after `terraform apply -target=aws_acm_certificate.site`; at Namecheap the Host field
# is relative, so the trailing ".<domain>." is dropped from each name.
output "acm_validation_records" {
  description = "Certificate validation records, as type / host / value."
  value = [
    for option in aws_acm_certificate.site.domain_validation_options :
    "${option.resource_record_type}  ${trimsuffix(option.resource_record_name, ".${local.web_domain}.")}  ${option.resource_record_value}"
  ]
}

# The apex cannot be a CNAME, so it is an ALIAS — Namecheap's own record type for exactly
# this, supported on BasicDNS. Any A, AAAA, CNAME or URL Redirect record already on that
# host has to go first, including the registrar's parking address.
output "dns_records_to_create" {
  description = "What to add at the registrar once the distribution exists."
  value = [
    "ALIAS  @    ${aws_cloudfront_distribution.site.domain_name}",
    "CNAME  www  ${aws_cloudfront_distribution.site.domain_name}",
  ]
}

output "site_url" {
  value = "https://${local.web_domain}/"
}

output "cloudfront_domain_name" {
  description = "Target of both DNS records above."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_id" {
  description = "What deploy.sh invalidates."
  value       = aws_cloudfront_distribution.site.id
}

output "site_bucket" {
  description = "What deploy.sh syncs web/ into."
  value       = module.site.id
}

output "certificate_arn" {
  value = aws_acm_certificate.site.arn
}

output "aws_region" {
  value = var.aws_region
}

output "aws_account_id" {
  description = "The account this stack is in. deploy.sh asserts the profile it was given resolves to it."
  value       = data.aws_caller_identity.current.account_id
}

output "content_security_policy" {
  description = "What CloudFront sends on every response here. Worth reading when the sign-in page cannot reach something."
  value       = local.content_security_policy
}
