
# # main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.20"  # Cập nhật lên AWS Provider 7.x
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


data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
  depends_on = [ module.eks ]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
  depends_on = [ module.eks ]
  
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  config_path    = "~/.kube/config" 

}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
    config_path    = "~/.kube/config" 
  }

}



