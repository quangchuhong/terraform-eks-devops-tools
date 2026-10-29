# modules/aws-load-balancer-controller/variables.tf
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