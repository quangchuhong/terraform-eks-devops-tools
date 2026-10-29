module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "eks-cluster-ver1"
  kubernetes_version = "1.34"

  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}

    vpc-cni                = {
      before_compute = true
    }

    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_iam.iam_role_arn
      most_recent = true
    }

  }

  enable_irsa = true
  # Optional
  endpoint_public_access = true

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # Example for an administrative IAM user
    admin_user_access = {
        principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" # Replace with your admin user ARN
        policy_associations = {
        admin_policy = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
            type = "cluster"
            }
         }
        }
    }
  }

  vpc_id                   = "vpc-03fb9f55496d71836"
  subnet_ids               = ["subnet-0189d8013dc13f181", "subnet-012955c7d5094705c", "subnet-0c403ad0b306974dc"]
  control_plane_subnet_ids = ["subnet-0189d8013dc13f181", "subnet-012955c7d5094705c", "subnet-0c403ad0b306974dc"]

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    eks_nodes = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD" # "AL2023_x86_64_STANDARD" # "BOTTLEROCKET_x86_64"
      instance_types = ["t3.xlarge"]

      min_size     = 2
      max_size     = 10
      desired_size = 3

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  shutdownGracePeriod: 30s
          EOT
        }
      ]

    }
  }

  tags = {
      "Environment"                                   = "dev" 
      "Terraform"                                     = "true"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"

    }
}

data "aws_caller_identity" "current" {}