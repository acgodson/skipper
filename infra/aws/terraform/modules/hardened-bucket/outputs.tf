output "id" {
  description = "Bucket name, for resources that take a bucket rather than an ARN."
  value       = aws_s3_bucket.this.id
}

output "arn" {
  description = "Bucket ARN, for IAM and bucket-policy statements the caller writes."
  value       = aws_s3_bucket.this.arn
}

# Depend on this, not on the bucket, when an order matters: it is the last thing the
# module creates, so it stands for "the bucket is hardened and its policy is in place".
output "policy_id" {
  description = "Id of the bucket policy, so a caller can order a writer after it."
  value       = aws_s3_bucket_policy.this.id
}
