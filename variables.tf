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

variable "vpc_id" {
  description = "vpc_id"
  type        = string
  default     = "vpc-03fb9f55496d71836"
}

variable "subnet_ids" {
  description = "subnet_ids"
  type        = list(string)
  default     = ["subnet-0189d8013dc13f181", "subnet-012955c7d5094705c", "subnet-0c403ad0b306974dc"]
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

# ---------- DNS / Route 53 ----------
variable "route53_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID của gitlabonlinecom.click (account 545983214264)"
  default     = "Z09980543QQOFQHVARDDQ"
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