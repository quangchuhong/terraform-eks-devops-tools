# modules/eks_cluster_autoscaler/main.tf

data "aws_iam_policy_document" "autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes",
      "sts:AssumeRole"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "autoscaler" {
  name        = "${var.cluster_name}-cluster-autoscaler"
  description = "Policy for Cluster Autoscaler"
  policy      = data.aws_iam_policy_document.autoscaler.json
}

module "irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.20.0"

  role_name = "${var.cluster_name}-cluster-autoscaler"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  role_policy_arns = {
    policy = aws_iam_policy.autoscaler.arn
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.helm_chart_version
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "fullnameOverride"
    value = "cluster-autoscaler" # 👈 Tên Kubernetes resources
  }

  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa.iam_role_arn
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }
  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "5m"
  }

  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = "5m"
  }

  depends_on = [module.eks]

}
