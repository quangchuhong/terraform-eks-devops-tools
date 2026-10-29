variable "region" {
  description = "Region đặt bucket state (trùng region của EKS)"
  type        = string
  default     = "ap-southeast-1"
}

variable "noncurrent_version_retention_days" {
  description = "Số ngày giữ các version cũ của state file"
  type        = number
  default     = 90
}
