
# data "aws_eks_cluster" "this" {
#   name = module.eks.cluster_name
#   depends_on = [ module.eks ]
# }

# data "aws_iam_openid_connect_provider" "eks" {
#   url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
# }

# data "tls_certificate" "eks_oidc" {
#   url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
# }


data "aws_iam_policy_document" "nexus_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:nexus:nexus"
      ]
    }
  }
}


resource "aws_iam_role" "nexus" {
  name               = "eks-nexus-role"
  assume_role_policy = data.aws_iam_policy_document.nexus_irsa_trust.json
}

data "aws_iam_policy_document" "nexus_s3_cache" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::nexus-data-bucket-s3"
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::nexus-data-bucket-s3/*"
    ]
  }
}

resource "aws_iam_policy" "nexus_s3_cache" {
  name   = "nexus-s3-cache"
  policy = data.aws_iam_policy_document.nexus_s3_cache.json
}

resource "aws_iam_role_policy_attachment" "nexus_s3_cache_attach" {
  role       = aws_iam_role.nexus.name
  policy_arn = aws_iam_policy.nexus_s3_cache.arn
}

data "aws_iam_policy_document" "nexus_deploy" {
  statement {
    sid = "S3Deploy"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:*"
    ]
    resources = [
      "arn:aws:s3:::nexus-data-bucket-s3",
      "arn:aws:s3:::nexus-data-bucket-s3/*"
    ]
  }

  statement {
    sid = "ECR"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["*"]
  }

  statement {
    sid = "EKSDescribe"
    actions = [
      "eks:DescribeCluster"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "nexus_deploy" {
  name   = "nexus-deploy"
  policy = data.aws_iam_policy_document.nexus_deploy.json
}

resource "aws_iam_role_policy_attachment" "nexus_deploy_attach" {
  role       = aws_iam_role.nexus.name
  policy_arn = aws_iam_policy.nexus_deploy.arn
}