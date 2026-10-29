# Lưu Terraform state trên S3 (bucket tạo bởi thư mục bootstrap/).
# use_lockfile = true: khoá state bằng file .tflock trên S3 (Terraform >= 1.11),
# không cần DynamoDB.
terraform {
  backend "s3" {
    bucket       = "tfstate-609320954321-ap-southeast-1" # account 609320954321
    key          = "eks-devops-tools/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
