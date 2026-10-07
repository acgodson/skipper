module "backups" {
  source = "./modules/hardened-bucket"

  bucket   = local.backup_bucket
  name_tag = "${local.name}-backups"
}

# Two prefixes, two retentions. db/ ages out; claims/ never expires, because losing a
# claim lets a Device ID be reissued to a second key (API.md §6.1).
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = module.backups.id

  rule {
    id     = "main-database"
    status = "Enabled"

    filter {
      prefix = "db/"
    }

    transition {
      days          = var.backup_ia_transition_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.backup_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.backup_expiration_days
    }
  }

  rule {
    id     = "claims-database"
    status = "Enabled"

    filter {
      prefix = "claims/"
    }

    transition {
      days          = var.backup_ia_transition_days
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "releases"
    status = "Enabled"

    filter {
      prefix = "releases/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [module.backups]
}
