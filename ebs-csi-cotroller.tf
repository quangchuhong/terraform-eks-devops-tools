data "tls_certificate" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

# 2. Tạo IAM role cho EBS CSI Driver
module "ebs_csi_iam" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name = "ebs-csi-controller-role"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  #depends_on = [module.eks]
}

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type = "gp3"
    encrypted = "true"  # Enable encryption by default
  }

  depends_on = [module.ebs_csi_iam]
}
