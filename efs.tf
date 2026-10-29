# resource "aws_security_group" "efs_jira_sg" {
#   name        = "efs-jira-sg"
#   description = "SG for Jira EFS"
#   vpc_id      = var.vpc_id

#   ingress {
#     description = "Allow NFS from EKS nodes"
#     from_port   = 2049
#     to_port     = 2049
#     protocol    = "tcp"
#     security_groups = [
#       module.eks.node_security_group_id # SG của node EKS / worker nodes
#     ]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = {
#     Name = "efs-jira-sg"
#   }
# }

# resource "aws_efs_file_system" "jira" {
#   creation_token = "jira-shared-home"
#   performance_mode = "generalPurpose"
#   throughput_mode  = "bursting"

#   encrypted = true

#   lifecycle_policy {
#     transition_to_ia = "AFTER_30_DAYS"
#   }

#   tags = {
#     Name = "jira-efs"
#   }
# }

# # Ví dụ: list subnet private nơi EKS node chạy
# # variable "private_subnet_ids" { type = list(string) }

# resource "aws_efs_mount_target" "jira" {
#   for_each = toset(var.subnet_ids)

#   file_system_id  = aws_efs_file_system.jira.id
#   subnet_id       = each.value
#   security_groups = [aws_security_group.efs_jira_sg.id]
# }
