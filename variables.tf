# ---------- EKS / mạng ----------
variable "cluster_name" {
  description = "EKS cluster name (dùng chung cho EKS, tag và Cluster Autoscaler)"
  type        = string
  default     = "eks-cluster-ver1"
}

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN"
  default     = ""
}

# VPC/subnet của account 609320954321 (default VPC, subnet public ở 3 AZ).
# Subnet dùng chung cho node EKS và ALB internet-facing → phải là subnet PUBLIC.
variable "vpc_id" {
  description = "VPC chạy EKS"
  type        = string
  default     = "vpc-0a7f2229b36e6ceb5"
}

variable "subnet_ids" {
  description = "Subnet public cho node EKS, control plane ENI và ALB"
  type        = list(string)
  default     = ["subnet-01e7b81b2c34fbaae", "subnet-0729b4d3570c85035", "subnet-063d005e791e4932f"]
}

# IAM user/role được quyền admin cụm EKS (ví dụ danh tính đăng nhập Console).
# Người chạy Terraform đã là admin sẵn → KHÔNG thêm lại ARN đó (trùng access entry).
# Không dùng root ("arn:aws:iam::<account>:root").
variable "cluster_admin_arns" {
  description = "ARN IAM user/role được cấp AmazonEKSClusterAdminPolicy trên cụm"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.cluster_admin_arns : !endswith(a, ":root")])
    error_message = "Access entry không nhận root user; dùng ARN của IAM user hoặc role."
  }
}

# ---------- Region ----------
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "ap-southeast-1"
}

# ---------- Cluster Autoscaler ----------
variable "helm_chart_version" {
  type        = string
  default     = "9.28.0"
  description = "Cluster Autoscaler Helm chart version"
}

# ---------- GitLab ----------
# Version của Helm chart gitlab/gitlab (KHÔNG phải version GitLab).
# Tra chart ↔ app version: helm search repo gitlab/gitlab --versions
# Chỉ nâng trong cùng minor (bản vá) bằng helm upgrade tại chỗ; nâng major phải theo upgrade path của GitLab.
variable "gitlab_chart_version" {
  type        = string
  description = "Version Helm chart gitlab/gitlab"
  default     = "9.11.16" # GitLab v18.11.14 (critical patch)
}

# ---------- DNS / Route 53 ----------
# Domain gốc cho mọi app (gitlab.<domain>, nexus.<domain>, ...).
# Terraform tạo hosted zone public cho domain này (dns.tf).
variable "domain" {
  type        = string
  description = "Domain gốc của các DevOps tool"
  default     = "gitlabonlinecom.click"
}

# true: domain được đăng ký bằng Route 53 trong CÙNG account → Terraform tự trỏ
# name server của domain về hosted zone (aws_route53domains_registered_domain).
# false: domain đăng ký ở nơi khác → tự trỏ NS theo output `name_servers`.
variable "manage_domain_nameservers" {
  type        = bool
  description = "Terraform quản lý name server của domain đăng ký bằng Route 53 trong account này"
  default     = true
}

# ALB do AWS Load Balancer Controller tạo bất đồng bộ SAU khi helm_release.gitlab xong,
# nên lần apply đầu chưa tìm được ALB. Apply 2 lượt:
#   1) terraform apply                                  (enable_dns_records = false)
#   2) kubectl get ingress -n gitlab → có ADDRESS
#      thêm `enable_dns_records = true` vào terraform.tfvars rồi terraform apply
#      (dùng -var một lần thì lần apply sau không có cờ sẽ XOÁ các bản ghi)
variable "enable_dns_records" {
  type        = bool
  description = "Tạo bản ghi Route 53 trỏ về ALB (bật ở lượt apply thứ 2, khi ALB đã tồn tại)"
  default     = false
}

variable "app_hostnames" {
  type        = list(string)
  description = "Các subdomain trỏ về ALB dùng chung (group alb-apps)"
  default = [
    "gitlab", "registry", "minio", "kas",
    "grafana", "prometheus", "alertmanager",
    "nexus", "docker", "docker-proxy", "docker-internal",
    "jenkins", "argocd", "sonarqube", "trivy", "jirasm",
  ]
}

# ---------- Jira RDS (đang tắt) ----------
/*
variable "db_name" {
  description = "Tên database cho Jira"
  default     = "jira_db"
}

variable "db_username" {
  description = "Username cho database"
  default     = "jiraadmin"
}

variable "db_password" {
  description = "Password cho database"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "Loại instance RDS"
  default     = "db.t3.medium"
}

variable "allocated_storage" {
  description = "Dung lượng storage (GB)"
  default     = 100
}


variable "environment" {
  description = "Môi trường (dev/staging/prod)"
  default     = "dev"
}
*/