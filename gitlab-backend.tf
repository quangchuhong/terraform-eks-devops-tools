# Dịch vụ ngoài cho GitLab 19 (chart 10.x đã bỏ PostgreSQL, Redis và MinIO đi kèm):
#   - Amazon RDS PostgreSQL 17      → global.psql
#   - Amazon ElastiCache Redis 7    → global.redis (TLS + AUTH)
#   - Amazon S3                     → object storage, registry, backups (IRSA, không access key)
# Mật khẩu sinh ngẫu nhiên, lưu thành Kubernetes Secret trong namespace gitlab.

locals {
  gitlab_namespace = "gitlab"
  gitlab_name      = "${var.cluster_name}-gitlab"

  # Bucket S3: tên phải unique toàn cầu → gắn account ID
  gitlab_bucket_prefix = "gitlab-${data.aws_caller_identity.current.account_id}"
  gitlab_bucket_keys = [
    "artifacts", "lfs", "uploads", "packages", "mr-diffs", "terraform-state",
    "ci-secure-files", "dependency-proxy", "agent-plan-content", "ci-catalog-bundles",
    "registry", "backups", "tmp",
  ]
  gitlab_buckets = { for k in local.gitlab_bucket_keys : k => "${local.gitlab_bucket_prefix}-${k}" }
}

# ---------- Network ----------
# Pod dùng IP của VPC CNI và security group của node → chỉ cho phép từ SG node/cluster.
resource "aws_security_group" "gitlab_data" {
  name        = "${local.gitlab_name}-data"
  description = "GitLab RDS PostgreSQL and ElastiCache Redis"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id, module.eks.cluster_primary_security_group_id]
  }

  ingress {
    description     = "Redis from EKS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id, module.eks.cluster_primary_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.gitlab_name}-data" }
}

# ---------- RDS PostgreSQL ----------
resource "random_password" "gitlab_db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "gitlab" {
  name       = local.gitlab_name
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "gitlab" {
  identifier     = local.gitlab_name
  engine         = "postgres"
  engine_version = var.gitlab_db_engine_version
  instance_class = var.gitlab_db_instance_class

  allocated_storage     = var.gitlab_db_allocated_storage
  max_allocated_storage = var.gitlab_db_allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "gitlabhq_production"
  username = "gitlab"
  password = random_password.gitlab_db.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.gitlab.name
  vpc_security_group_ids = [aws_security_group.gitlab_data.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection       = var.gitlab_db_deletion_protection
  skip_final_snapshot       = !var.gitlab_db_deletion_protection
  final_snapshot_identifier = var.gitlab_db_deletion_protection ? "${local.gitlab_name}-final" : null

  tags = { Application = "gitlab" }
}

# ---------- ElastiCache Redis ----------
resource "random_password" "gitlab_redis" {
  length  = 32
  special = false
}

resource "aws_elasticache_subnet_group" "gitlab" {
  name       = local.gitlab_name
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "gitlab" {
  replication_group_id = local.gitlab_name
  description          = "GitLab Redis"
  engine               = "redis"
  engine_version       = "7.1"
  parameter_group_name = "default.redis7"
  node_type            = var.gitlab_redis_node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.gitlab.name
  security_group_ids = [aws_security_group.gitlab_data.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true # GitLab dùng scheme rediss
  auth_token                 = random_password.gitlab_redis.result
  automatic_failover_enabled = false
  apply_immediately          = true

  tags = { Application = "gitlab" }
}

# ---------- S3 ----------
resource "aws_s3_bucket" "gitlab" {
  for_each      = local.gitlab_buckets
  bucket        = each.value
  force_destroy = var.gitlab_s3_force_destroy

  tags = { Application = "gitlab" }
}

resource "aws_s3_bucket_public_access_block" "gitlab" {
  for_each                = aws_s3_bucket.gitlab
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab" {
  for_each = aws_s3_bucket.gitlab
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------- IAM (IRSA) cho các ServiceAccount của GitLab ----------
# Mọi ServiceAccount do chart tạo trong namespace gitlab được gắn role này
# (global.serviceAccount.annotations) → webservice, sidekiq, toolbox, registry, migrations.
data "aws_iam_policy_document" "gitlab_irsa_trust" {
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
      test     = "StringLike"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.gitlab_namespace}:*"]
    }
  }
}

resource "aws_iam_role" "gitlab_s3" {
  name               = "${local.gitlab_name}-s3"
  assume_role_policy = data.aws_iam_policy_document.gitlab_irsa_trust.json
}

data "aws_iam_policy_document" "gitlab_s3" {
  statement {
    sid       = "Buckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [for b in aws_s3_bucket.gitlab : b.arn]
  }
  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
    ]
    resources = [for b in aws_s3_bucket.gitlab : "${b.arn}/*"]
  }
}

resource "aws_iam_role_policy" "gitlab_s3" {
  name   = "gitlab-s3"
  role   = aws_iam_role.gitlab_s3.id
  policy = data.aws_iam_policy_document.gitlab_s3.json
}

# ---------- Kubernetes: namespace + secrets ----------
resource "kubernetes_namespace_v1" "gitlab" {
  metadata {
    name = local.gitlab_namespace
  }
  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "gitlab_postgresql" {
  metadata {
    name      = "gitlab-postgresql-password"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    "postgresql-password" = random_password.gitlab_db.result
  }
}

resource "kubernetes_secret_v1" "gitlab_redis" {
  metadata {
    name      = "gitlab-redis-secret"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    "redis-password" = random_password.gitlab_redis.result
  }
}

# Object storage cho Rails (LFS, artifacts, uploads, packages, ...): dùng IAM role, không access key
resource "kubernetes_secret_v1" "gitlab_rails_storage" {
  metadata {
    name      = "gitlab-rails-storage"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    connection = yamlencode({
      provider        = "AWS"
      use_iam_profile = true
      region          = var.region
    })
  }
}

# Storage driver S3 cho Container Registry
resource "kubernetes_secret_v1" "gitlab_registry_storage" {
  metadata {
    name      = "gitlab-registry-storage"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }
  data = {
    config = yamlencode({
      s3 = {
        bucket = local.gitlab_buckets["registry"]
        region = var.region
        v4auth = true
      }
    })
  }
}

output "gitlab_db_endpoint" {
  value = aws_db_instance.gitlab.address
}

output "gitlab_redis_endpoint" {
  value = aws_elasticache_replication_group.gitlab.primary_endpoint_address
}
