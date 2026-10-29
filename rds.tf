
# # Security group cho RDS
# resource "aws_security_group" "jira_rds_sg" {
#   name        = "jira-rds-sg-${var.environment}"
#   description = "Security group cho Jira RDS"
#   vpc_id      = var.vpc_id

#   ingress {
#     from_port   = 5432
#     to_port     = 5432
#     protocol    = "tcp"
#     cidr_blocks = ["10.0.0.0/16","172.31.0.0/16"] # Thay đổi CIDR theo VPC của bạn
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = {
#     Name        = "jira-rds-sg"
#     Environment = var.environment
#     Application = "Jira"
#   }
# }

# # DB subnet group
# resource "aws_db_subnet_group" "jira_db_subnet_group" {
#   name       = "jira-db-subnet-group-${var.environment}"
#   subnet_ids = var.subnet_ids

#   tags = {
#     Name        = "jira-db-subnet-group"
#     Environment = var.environment
#   }
# }

# # RDS PostgreSQL instance
# resource "aws_db_instance" "jira_postgresql" {
#   identifier = "jira-postgresql-${var.environment}"

#   engine         = "postgres"
#   engine_version = "13.23" # Phiên bản PostgreSQL (Jira hỗ trợ từ 12.x trở lên)
#   instance_class = var.db_instance_class

#   allocated_storage     = var.allocated_storage
#   storage_type         = "gp3"
#   storage_encrypted    = true
#   kms_key_id           = data.aws_kms_key.rds_kms_key.arn

#   db_name  = var.db_name
#   username = var.db_username
#   password = var.db_password
#   port     = 5432

#   vpc_security_group_ids = [aws_security_group.jira_rds_sg.id]
#   db_subnet_group_name   = aws_db_subnet_group.jira_db_subnet_group.name

#   multi_az               = var.environment == "prod" ? true : false
#   publicly_accessible    = false
#   deletion_protection    = var.environment == "prod" ? true : false

#   backup_retention_period = 7
#   backup_window          = "03:00-04:00"
#   maintenance_window     = "sun:04:00-sun:05:00"

#   apply_immediately       = var.environment != "prod" ? true : false
#   skip_final_snapshot     = var.environment != "prod" ? true : false
#   final_snapshot_identifier = var.environment == "prod" ? "jira-db-final-snapshot" : null

#   performance_insights_enabled = true
#   performance_insights_retention_period = 7

#   parameter_group_name = aws_db_parameter_group.jira_postgresql_pg.name
#   option_group_name    = aws_db_option_group.jira_postgresql_og.name

#   tags = {
#     Name        = "jira-postgresql"
#     Environment = var.environment
#     Application = "Jira"
#   }
# }

# # DB parameter group
# resource "aws_db_parameter_group" "jira_postgresql_pg" {
#   name   = "jira-postgresql-pg-${var.environment}"
#   family = "postgres13"

#   parameter {
#     name  = "shared_preload_libraries"
#     value = "pg_stat_statements"
#   }

#   parameter {
#     name  = "log_statement"
#     value = "ddl"
#   }

#   parameter {
#     name  = "log_min_duration_statement"
#     value = "1000"
#   }

#   tags = {
#     Name        = "jira-postgresql-pg"
#     Environment = var.environment
#   }
# }

# # DB option group
# resource "aws_db_option_group" "jira_postgresql_og" {
#   name                 = "jira-postgresql-og-${var.environment}"
#   engine_name          = "postgres"
#   major_engine_version = "13"

#   tags = {
#     Name        = "jira-postgresql-og"
#     Environment = var.environment
#   }
# }
