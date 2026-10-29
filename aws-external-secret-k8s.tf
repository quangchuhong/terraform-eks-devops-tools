
# # Tạo IAM Policy
# resource "aws_iam_policy" "secrets_manager_policy" {
#   name        = "eks-secrets-manager-policy"
#   description = "Policy for accessing AWS Secrets Manager"
#   policy      = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect   = "Allow"
#         Action   = [
#           "secretsmanager:GetSecretValue",
#           "secretsmanager:DescribeSecret",
#           "secretsmanager:ListSecrets"
#         ]
#         Resource = "*"
#       }
#     ]
#   })
# }

# # Tạo IAM Role
# resource "aws_iam_role" "external_secrets_role" {
#   name = "external-secrets-manager-role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action    = "sts:AssumeRoleWithWebIdentity"
#         Effect    = "Allow"
#         Principal = {
#           Federated = module.eks.oidc_provider_arn
#         }
#         Condition = {
#           StringEquals = {
#             "${module.eks.oidc_provider}:sub" = "system:serviceaccount:nexus:external-secrets-sa"
#           }
#         }
#       }
#     ]
#   })
# }

# # Gắn IAM Policy vào IAM Role
# resource "aws_iam_role_policy_attachment" "secrets_manager_policy_attachment" {
#   role       = aws_iam_role.external_secrets_role.name
#   policy_arn = aws_iam_policy.secrets_manager_policy.arn
# }

# resource "helm_release" "external_secrets" {
#   name       = "external-secrets"
#   repository = "https://charts.external-secrets.io"
#   chart      = "external-secrets"
#   namespace  = "nexus"

#   set {
#       name  = "installCRDs"
#       value = "true"
#     }

#   set {
#     name  = "serviceAccount.create"
#     value = "true"
#   }

#   set {
#     name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = aws_iam_role.external_secrets_role.arn
#   }

#   set {
#     name  = "serviceAccount.name"
#     value = "external-secrets-sa"
#   }
# }


# resource "kubernetes_namespace" "nexus" {
#   metadata {
#     name = "nexus"
#   }
#   depends_on = [ module.eks ]
# }



# # Tạo AWS Secret
# resource "aws_secretsmanager_secret" "nexus_db_secret" {
#   name = "nexus-db-secret"
# }

# # Thêm giá trị vào Secret
# resource "aws_secretsmanager_secret_version" "nexus_db_secret_version" {
#   secret_id     = aws_secretsmanager_secret.nexus_db_secret.id
#   secret_string = jsonencode({
#     db_host     = "${module.rds.db_instance_address}"
#     db_user     = "nexus_admin"
#     db_password = "Tcb@120456"
#     db_name     = "nexus"
#   })
#   depends_on = [ module.rds ]
# }

# # Xuất Secret ARN để sử dụng trong Kubernetes
# output "secret_arn" {
#   value = aws_secretsmanager_secret.nexus_db_secret.arn
# }

# resource "kubectl_manifest" "external_secrets_store" {
#   yaml_body = file("${path.module}/helm-chart/external-secret-store.yaml")
#   depends_on = [ helm_release.external_secrets ]
# }

# resource "kubectl_manifest" "external_secrets_nexus_db" {
#   yaml_body = file("${path.module}/helm-chart/nexus-db-external-secret.yaml")
#   depends_on = [ kubectl_manifest.external_secrets_store ]
# }