# Jenkins artifacts and stashes on S3 (plugin artifact-manager-s3), so they never go through
# or stay on the controller's JENKINS_HOME. The controller signs URLs with its IRSA role and
# agents upload/download directly to S3.

# data.aws_caller_identity.current is declared in eks.tf

locals {
  jenkins_namespace       = "jenkins"
  jenkins_service_account = "jenkins"
  jenkins_artifacts_name  = "jenkins-${data.aws_caller_identity.current.account_id}-artifacts"
}

# ---------- KMS key (customer managed, rotated yearly) ----------
resource "aws_kms_key" "jenkins_artifacts" {
  description             = "Jenkins artifacts bucket (${var.cluster_name})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = { Application = "jenkins" }
}

resource "aws_kms_alias" "jenkins_artifacts" {
  name          = "alias/${var.cluster_name}-jenkins-artifacts"
  target_key_id = aws_kms_key.jenkins_artifacts.key_id
}

# ---------- Bucket ----------
resource "aws_s3_bucket" "jenkins_artifacts" {
  bucket = local.jenkins_artifacts_name
  tags   = { Application = "jenkins" }
}

resource "aws_s3_bucket_public_access_block" "jenkins_artifacts" {
  bucket                  = aws_s3_bucket.jenkins_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.jenkins_artifacts.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "jenkins_artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id

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
      days = var.jenkins_artifacts_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.jenkins_artifacts]
}

# TLS only
data "aws_iam_policy_document" "jenkins_artifacts_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.jenkins_artifacts.arn, "${aws_s3_bucket.jenkins_artifacts.arn}/*"]
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

resource "aws_s3_bucket_policy" "jenkins_artifacts" {
  bucket     = aws_s3_bucket.jenkins_artifacts.id
  policy     = data.aws_iam_policy_document.jenkins_artifacts_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.jenkins_artifacts]
}

# ---------- IRSA: only the jenkins service account (controller) ----------
data "aws_iam_policy_document" "jenkins_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.jenkins_namespace}:${local.jenkins_service_account}"]
    }
  }
}

resource "aws_iam_role" "jenkins_artifacts" {
  name               = "${var.cluster_name}-jenkins-artifacts"
  assume_role_policy = data.aws_iam_policy_document.jenkins_irsa_trust.json
  tags               = { Application = "jenkins" }
}

data "aws_iam_policy_document" "jenkins_artifacts" {
  statement {
    sid       = "Bucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.jenkins_artifacts.arn]
  }
  statement {
    sid       = "Objects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.jenkins_artifacts.arn}/*"]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.jenkins_artifacts.arn]
  }
}

resource "aws_iam_role_policy" "jenkins_artifacts" {
  name   = "jenkins-artifacts-s3"
  role   = aws_iam_role.jenkins_artifacts.id
  policy = data.aws_iam_policy_document.jenkins_artifacts.json
}

output "jenkins_artifacts_bucket" {
  description = "S3 bucket for Jenkins artifacts (artifact-manager-s3)"
  value       = aws_s3_bucket.jenkins_artifacts.bucket
}

output "jenkins_artifacts_role_arn" {
  description = "IRSA role of the jenkins service account"
  value       = aws_iam_role.jenkins_artifacts.arn
}
