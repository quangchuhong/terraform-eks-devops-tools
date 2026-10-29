
# # main.tf
terraform {
  required_version = ">= 1.11" # use_lockfile của backend S3 cần >= 1.11
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20" # Cập nhật lên AWS Provider 7.x
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0" # Cập nhật lên Helm Provider 2.14.x
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0" # Cập nhật lên Kubernetes Provider 3.x
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

}

provider "aws" {
  region = "ap-southeast-1"
}


# Xác thực tới EKS bằng `aws eks get-token` (token luôn mới, không phụ thuộc ~/.kube/config).
# Lần đầu dựng cụm: terraform apply -target=module.eks, sau đó terraform apply.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", "ap-southeast-1"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", "ap-southeast-1"]
    }
  }
}
