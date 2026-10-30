# Archive of Jenkins build logs (Console Output) and build metadata (build.xml) on S3.
# A sidecar in the controller pod (helm-install/jenkins/jenkins/values-build-logs.yaml) uploads
# each finished build once. JENKINS_HOME then only keeps recent builds for the UI, and S3 keeps
# the immutable audit copy (Object Lock) for 12 months.
#
# Reuses the KMS key and the IRSA role from jenkins-storage.tf. The role can write and list but
# cannot delete, so Jenkins cannot alter what is already archived.

locals {
  jenkins_build_logs_name = "jenkins-${data.aws_caller_identity.current.account_id}-build-logs"
}

resource "aws_s3_bucket" "jenkins_build_logs" {
  bucket              = local.jenkins_build_logs_name
  object_lock_enabled = true # only settable at creation; also turns on versioning
  tags                = { Application = "jenkins" }
}

resource "aws_s3_bucket_public_access_block" "jenkins_build_logs" {
  bucket                  = aws_s3_bucket.jenkins_build_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "jenkins_build_logs" {
  bucket = aws_s3_bucket.jenkins_build_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "jenkins_build_logs" {
  bucket = aws_s3_bucket.jenkins_build_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "jenkins_build_logs" {
  bucket = aws_s3_bucket.jenkins_build_logs.id
  rule {
    default_retention {
      mode = var.jenkins_build_logs_lock_mode
      days = var.jenkins_build_logs_lock_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.jenkins_build_logs]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "jenkins_build_logs" {
  bucket = aws_s3_bucket.jenkins_build_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.jenkins_artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "jenkins_build_logs" {
  bucket = aws_s3_bucket.jenkins_build_logs.id

  rule {
    id     = "tiering-and-retention"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = var.jenkins_build_logs_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.jenkins_build_logs]
}

data "aws_iam_policy_document" "jenkins_build_logs_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.jenkins_build_logs.arn, "${aws_s3_bucket.jenkins_build_logs.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "jenkins_build_logs" {
  bucket     = aws_s3_bucket.jenkins_build_logs.id
  policy     = data.aws_iam_policy_document.jenkins_build_logs_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.jenkins_build_logs]
}

# Write-once access for the jenkins service account (no DeleteObject, no lock bypass)
data "aws_iam_policy_document" "jenkins_build_logs" {
  statement {
    sid       = "Bucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.jenkins_build_logs.arn]
  }
  statement {
    sid       = "Objects"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.jenkins_build_logs.arn}/*"]
  }
}

resource "aws_iam_role_policy" "jenkins_build_logs" {
  name   = "jenkins-build-logs-s3"
  role   = aws_iam_role.jenkins_artifacts.id
  policy = data.aws_iam_policy_document.jenkins_build_logs.json
}

output "jenkins_build_logs_bucket" {
  description = "S3 bucket for archived Jenkins build logs"
  value       = aws_s3_bucket.jenkins_build_logs.bucket
}
