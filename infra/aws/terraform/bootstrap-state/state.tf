# Where the root module's state lives. It is split out because a configuration cannot
# create the bucket it uses as its own backend, and it matters because the root module's
# state is as sensitive as the secrets in it: aws_cognito_identity_provider takes the
# Apple .p8 and the Google client secret as literal arguments, so enabling social sign-in
# writes both into state in the clear. That has to land in an encrypted, versioned,
# locked, private bucket, and it has to be true before the first apply that holds a
# secret rather than after it.

# Deleting this key makes every stored state version unreadable, which is why the
# deletion window is the long one and prevent_destroy is on. Rotation is safe here, unlike
# the id-cert key: symmetric KMS rotation keeps every previous key version for decryption,
# so old state stays readable.
resource "aws_kms_key" "state" {
  description             = "${local.name} terraform state encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.state_key.json

  tags = { Name = "${local.name}-tfstate" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# The AWS default key policy: the account root holds the key, and who may actually use it
# is decided by IAM. That is deliberate — the only principal that needs this key is
# whoever is running Terraform, and that identity comes from Identity Center rather than
# from anything this module can name (docs/PHASE5.md §4 step 4).
data "aws_iam_policy_document" "state_key" {
  statement {
    sid       = "AccountOwnsTheKey"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  tags = { Name = "${local.name}-tfstate" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is not optional for a state bucket: it is the only way back from a state
# file that an interrupted apply left truncated or wrong.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

# Superseded versions expire, because each one is a copy of every secret the state held
# at the time. Keeping them forever would quietly turn the bucket into an archive of
# every Apple key and Google client secret the stack has ever been configured with.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Both of these deny only a request that asks for the wrong encryption, never one that
  # asks for none: a PutObject with no encryption header is the normal case and gets the
  # bucket's default, which is this key. Denying the absent header instead would break
  # every ordinary upload and teach nobody anything.
  statement {
    sid       = "DenyTheWrongEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyTheWrongKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# State locking. The pinned Terraform is 1.9.8, whose S3 backend has no `use_lockfile`
# argument at all — it rejects it as an unsupported argument, exactly as it rejects an
# invented one — so the lock is a DynamoDB table. infra/aws/README.md "State" records the
# check and what to do when Terraform 1.10 or later is adopted.
#
# On-demand billing because the table takes one write per apply and nothing between them.
resource "aws_dynamodb_table" "state_lock" {
  name                        = local.table
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "LockID"
  deletion_protection_enabled = true

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  tags = { Name = "${local.name}-tfstate-lock" }
}
