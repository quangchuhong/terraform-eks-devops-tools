module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = "1.34"

  addons = {
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}

    vpc-cni = {
      before_compute = true
    }

    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_iam.iam_role_arn
      most_recent              = true
    }

  }

  enable_irsa = true
  # Optional
  endpoint_public_access = true

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  # Người chạy Terraform đã là admin nhờ enable_cluster_creator_admin_permissions.
  # Thêm admin khác (root, IAM user/role dùng cho Console...) qua var.cluster_admin_arns.
  # Lưu ý: không thêm chính người tạo cụm (trùng access entry).
  access_entries = {
    for arn in var.cluster_admin_arns : (endswith(arn, ":root") ? "root" : replace(element(split("/", arn), length(split("/", arn)) - 1), ".", "-")) => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.subnet_ids

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    eks_nodes = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_STANDARD" # "AL2023_x86_64_STANDARD" # "BOTTLEROCKET_x86_64"
      instance_types = ["t3.xlarge"]

      min_size     = 2
      max_size     = 10
      desired_size = 3

      # Root volume (images + emptyDir/ephemeral storage). The 20 GiB default ran out:
      # CI pods (Trivy Java DB, docker-in-docker, Maven) were evicted for ephemeral-storage.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

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