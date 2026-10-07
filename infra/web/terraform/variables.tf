variable "aws_region" {
  description = "Region the bucket and the state live in. The certificate is in us-east-1 regardless; CloudFront itself is global."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Common tag value and name prefix. Must match the backend stack, because its state key is derived from the same pair."
  type        = string
  default     = "skipperdesk"
}

variable "environment" {
  description = "Deployment name; part of every resource name."
  type        = string
  default     = "prod"
}

variable "backend_state_bucket" {
  description = "Bucket holding the backend stack's state, read for the Cognito and API values. No default: the name carries the account id. It is the 'bucket' line of the backend.hcl that bootstrap-state printed."
  type        = string
}

variable "backend_state_key" {
  description = "Object key of the backend stack's state in that bucket — the 'key' line of its backend.hcl, which is <environment>/terraform.tfstate."
  type        = string
  default     = "prod/terraform.tfstate"
}

variable "site_bucket_name" {
  description = "Bucket the site is served from. Empty means <project>-<environment>-web-<account id>. It is private: only CloudFront reads it."
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront edge locations to use. PriceClass_100 is North America and Europe, which is where the audience is and the cheapest tier; a Mac in Asia still reaches it, over a longer first hop."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "html_max_ttl_seconds" {
  description = "Longest CloudFront will hold a page or /config.js. The objects themselves are uploaded no-cache, so this is only the ceiling; it exists so a deploy that forgets to invalidate still corrects itself quickly."
  type        = number
  default     = 300
}

variable "asset_ttl_seconds" {
  description = "How long CloudFront holds anything under /assets/. There is no build step and so no content hash in the filenames; the cache key includes the query string instead, and the pages ask for assets/styles.css?v=N. Bumping N in the HTML — which is never cached for long — is the cache bust."
  type        = number
  default     = 31536000
}

variable "certificate_issue_timeout" {
  description = "How long the apply waits for the certificate to be issued after the owner adds the validation records by hand. Namecheap publishes within minutes; the wait is generous because a short one fails the apply rather than the certificate."
  type        = string
  default     = "75m"
}
