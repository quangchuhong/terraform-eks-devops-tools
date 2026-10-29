# 1. Cài đặt GitLab bằng Helm
resource "helm_release" "gitlab" {
  name             = "gitlab"
  repository       = "https://charts.gitlab.io/"
  chart            = "gitlab"
  version          = var.gitlab_chart_version
  namespace        = "gitlab"
  create_namespace = true

  values = [
    file("${path.module}/helm-chart/gitlab-values.yaml"),
    # Giá trị phụ thuộc account: subnet của ALB lấy từ var.subnet_ids
    yamlencode({
      global = {
        ingress = {
          annotations = {
            "alb.ingress.kubernetes.io/subnets" = join(", ", var.subnet_ids)
          }
        }
      }
    })
  ]

  set {
    name  = "global.hosts.domain"
    value = var.domain
  }

  set {
    name  = "certmanager-issuer.email"
    value = "quang.hong.0991@gmail.com"
  }

  timeout = 600 # 10 phút (mặc định: 300s)

  depends_on = [module.eks, module.eks.eks_managed_node_group,
    helm_release.lb_controller, helm_release.cluster_autoscaler,
    helm_release.metrics_server_release
  ]
}

# gitlab-runner:

data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "tls_certificate" "eks_oidc" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "gitlab_runner_irsa_trust" {
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
        "system:serviceaccount:gitlab-runner:gitlab-runner"
      ]
    }
  }
}

resource "aws_iam_role" "gitlab_runner" {
  name               = "eks-gitlab-runner-role"
  assume_role_policy = data.aws_iam_policy_document.gitlab_runner_irsa_trust.json
}

data "aws_iam_policy_document" "gitlab_runner_s3_cache" {
  statement {
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::gitlab-runner-cache-local"
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:aws:s3:::gitlab-runner-cache-local/*"
    ]
  }
}

resource "aws_iam_policy" "gitlab_runner_s3_cache" {
  name   = "gitlab-runner-s3-cache"
  policy = data.aws_iam_policy_document.gitlab_runner_s3_cache.json
}

resource "aws_iam_role_policy_attachment" "gitlab_runner_s3_cache_attach" {
  role       = aws_iam_role.gitlab_runner.name
  policy_arn = aws_iam_policy.gitlab_runner_s3_cache.arn
}

data "aws_iam_policy_document" "gitlab_runner_deploy" {
  statement {
    sid = "S3Deploy"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::your-deploy-bucket",
      "arn:aws:s3:::your-deploy-bucket/*"
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

resource "aws_iam_policy" "gitlab_runner_deploy" {
  name   = "gitlab-runner-deploy"
  policy = data.aws_iam_policy_document.gitlab_runner_deploy.json
}

resource "aws_iam_role_policy_attachment" "gitlab_runner_deploy_attach" {
  role       = aws_iam_role.gitlab_runner.name
  policy_arn = aws_iam_policy.gitlab_runner_deploy.arn
}

# 2. Lấy thông tin Ingress từ Helm chart đã cài đặt
data "kubernetes_ingress_v1" "gitlab" {
  metadata {
    name      = "gitlab-webservice-default" # Tên Ingress do GitLab chart tạo
    namespace = "gitlab"
  }

  depends_on = [helm_release.gitlab]
}


# ALB của group alb-apps: lấy DNS name trực tiếp từ Ingress GitLab (status.loadBalancer),
# không tìm theo tag → không nhầm với ALB khác trùng tag còn sót trong account.
locals {
  alb_dns_name = try(data.kubernetes_ingress_v1.gitlab.status[0].load_balancer[0].ingress[0].hostname, "")
}

# Canonical hosted zone ID của ALB trong region hiện tại (dùng cho alias record)
data "aws_lb_hosted_zone_id" "main" {}

output "alb_zone_id" {
  value = data.aws_lb_hosted_zone_id.main.id
}

output "alb_dns_name" {
  value = local.alb_dns_name
}

# Bật bằng var.enable_dns_records (xem variables.tf) khi Ingress đã có ADDRESS
resource "aws_route53_record" "apps" {
  for_each = var.enable_dns_records ? toset(var.app_hostnames) : toset([])

  zone_id = aws_route53_zone.main.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"

  alias {
    name                   = "dualstack.${local.alb_dns_name}"
    zone_id                = data.aws_lb_hosted_zone_id.main.id
    evaluate_target_health = true
  }

  lifecycle {
    precondition {
      condition     = local.alb_dns_name != ""
      error_message = "Ingress gitlab-webservice-default chưa có ADDRESS (ALB chưa tạo xong). Kiểm tra: kubectl get ingress -n gitlab"
    }
  }
}
