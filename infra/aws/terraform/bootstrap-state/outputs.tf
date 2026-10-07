output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "state_lock_table" {
  value = aws_dynamodb_table.state_lock.name
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "state_key" {
  description = "Object key the root module's state is written to."
  value       = local.state_key
}

# The root module's backend block cannot interpolate, and the bucket name and the key ARN
# both carry the account id, which does not belong in the repository. So the backend is a
# partial configuration and this output is the rest of it, written to a file that is
# gitignored. infra/aws/README.md "State" has the two commands.
output "backend_config" {
  description = "Write to ../backend.hcl, then: terraform init -backend-config=backend.hcl"
  value = join("\n", [
    "bucket         = \"${aws_s3_bucket.state.id}\"",
    "key            = \"${local.state_key}\"",
    "region         = \"${var.aws_region}\"",
    "dynamodb_table = \"${aws_dynamodb_table.state_lock.name}\"",
    "kms_key_id     = \"${aws_kms_key.state.arn}\"",
    "encrypt        = true",
  ])
}
