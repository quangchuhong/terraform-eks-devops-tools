# # Trust policy cho IRSA dùng OIDC của module.eks
# data "aws_iam_policy_document" "efs_csi_irsa_assume_role" {
#   statement {
#     effect = "Allow"

#     principals {
#       type        = "Federated"
#       identifiers = [module.eks.oidc_provider_arn]
#     }

#     actions = ["sts:AssumeRoleWithWebIdentity"]

#     condition {
#       test     = "StringEquals"
#       variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
#       values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
#     }
#   }
# }

# resource "aws_iam_role" "efs_csi_controller" {
#   name               = "efs-csi-controller-role"
#   assume_role_policy = data.aws_iam_policy_document.efs_csi_irsa_assume_role.json
# }

# resource "aws_iam_role_policy_attachment" "efs_csi_controller_attach" {
#   role       = aws_iam_role.efs_csi_controller.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
# }



# resource "kubernetes_service_account_v1" "efs_csi_controller_sa" {
#   metadata {
#     name      = "efs-csi-controller-sa"
#     namespace = "kube-system"

#     annotations = {
#       "eks.amazonaws.com/role-arn" = aws_iam_role.efs_csi_controller.arn
#     }
#   }
# }


# resource "helm_release" "aws_efs_csi_driver" {
#   name       = "aws-efs-csi-driver"
#   namespace  = "kube-system"
#   repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver"
#   chart      = "aws-efs-csi-driver"
#   version    = "2.5.0" # kiểm tra version mới nhất trên repo

#   # Không tạo SA trong chart, dùng SA Terraform tạo (có IRSA)
#   set {
#     name  = "controller.serviceAccount.create"
#     value = "false"
#   }

#   set {
#     name  = "controller.serviceAccount.name"
#     value = kubernetes_service_account_v1.efs_csi_controller_sa.metadata[0].name
#   }

#   # Image region ap-southeast-1
#   set {
#     name  = "image.repository"
#     value = "602401143452.dkr.ecr.ap-southeast-1.amazonaws.com/eks/aws-efs-csi-driver"
#   }

#   depends_on = [
#     kubernetes_service_account_v1.efs_csi_controller_sa
#   ]
# }


# resource "kubernetes_storage_class_v1" "efs_sc" {
#   metadata {
#     name = "efs-sc"
#   }

#   # đúng với provider kubernetes mới
#   storage_provisioner = "efs.csi.aws.com"

#   parameters = {
#     fileSystemId     = aws_efs_file_system.jira.id
#     directoryPerms   = "700"
#     provisioningMode = "efs-ap"
#   }

#   reclaim_policy      = "Retain"
#   volume_binding_mode = "WaitForFirstConsumer"

#   depends_on = [
#     helm_release.aws_efs_csi_driver,
#     aws_efs_mount_target.jira
#   ]
# }

