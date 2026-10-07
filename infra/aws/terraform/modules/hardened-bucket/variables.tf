variable "bucket" {
  description = "Bucket name. The caller computes it, because only the caller knows whether it carries the account id."
  type        = string
}

variable "name_tag" {
  description = "Value of the Name tag. Every other tag comes from the provider's default_tags."
  type        = string
}

variable "extra_policy_documents" {
  description = "Rendered aws_iam_policy_document JSON merged into the bucket policy alongside the TLS-only deny. Statement sids must not collide with DenyUnencryptedTransport."
  type        = list(string)
  default     = []
}
