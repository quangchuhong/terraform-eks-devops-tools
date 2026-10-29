# 1. Cài đặt GitLab bằng Helm
resource "helm_release" "gitlab" {
  name       = "gitlab"
  repository = "https://charts.gitlab.io/"
  chart      = "gitlab"
  version    = "9.11.5"
  namespace  = "gitlab"
  create_namespace = true

  values = [
    file("${path.module}/helm-chart/gitlab-values.yaml")
  ]

  set {
    name  = "global.hosts.domain"
    value = "gitlabonlinecom.click"
  }

  set {
    name  = "certmanager-issuer.email"
    value = "quang.hong.0991@gmail.com"
  }

  timeout    = 600 # 10 phút (mặc định: 300s)


  depends_on = [ module.eks, module.eks.eks_managed_node_group,
                helm_release.lb_controller, helm_release.cluster_autoscaler,
                helm_release.metrics_server_release
             ]
}

# gitlab-runner:

data "aws_eks_cluster" "this" {
  name = module.eks.cluster_name
  depends_on = [ module.eks ]
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


variable "route53_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID (ví dụ: Z1ABC234DEFG56)"
  default     = "Z08613522NHM48MOSOSYV"
}

data "aws_lb" "selected" {
 #name = "gitlab-webservice-default"  # Thay thế bằng tên ALB của bạn
 tags = {
    Environment = "prod"
    Application = "gitlab-alb"
  }

  depends_on = [helm_release.gitlab ]
}


# Lấy Zone ID (Canonical Hosted Zone ID)
output "alb_zone_id" {
  value = data.aws_lb.selected.zone_id
}


# Lấy DNS name của ALB
output "alb_dns_name" {
  value = data.aws_lb.selected.dns_name
}



# 5. Tạo Route53 Record
resource "aws_route53_record" "gitlab" {
  zone_id = var.route53_zone_id
  name    = "gitlab.gitlabonlinecom.click"
  type    = "A"

  alias {
    #name                   = "dualstack.${data.kubernetes_ingress_v1.gitlab.status[0].load_balancer[0].ingress[0].hostname}"
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id                  
    evaluate_target_health = true
  }
}


resource "aws_route53_record" "grafana" {
  zone_id = var.route53_zone_id
  name    = "grafana.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "prometheus" {
  zone_id = var.route53_zone_id
  name    = "prometheus.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "alertmanager" {
  zone_id = var.route53_zone_id
  name    = "alertmanager.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "nexus" {
  zone_id = var.route53_zone_id
  name    = "nexus.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "jenkins" {
  zone_id = var.route53_zone_id
  name    = "jenkins.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "argocd" {
  zone_id = var.route53_zone_id
  name    = "argocd.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "sonarqube" {
  zone_id = var.route53_zone_id
  name    = "sonarqube.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}



resource "aws_route53_record" "docker" {
  zone_id = var.route53_zone_id
  name    = "docker.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "docker-proxy" {
  zone_id = var.route53_zone_id
  name    = "docker-proxy.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "docker-internal" {
  zone_id = var.route53_zone_id
  name    = "docker-internal.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "jirasm" {
  zone_id = var.route53_zone_id
  name    = "jirasm.gitlabonlinecom.click"
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.selected.dns_name}"  
    zone_id                = data.aws_lb.selected.zone_id
    evaluate_target_health = true
  }
}
