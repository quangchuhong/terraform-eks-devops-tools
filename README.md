# terraform-eks-devops-tools

Terraform dựng cụm Amazon EKS và cài các DevOps tool (GitLab, Nexus, Jenkins, Argo CD, SonarQube, ...) bằng Helm.

## Terraform state trên S3

State được lưu trên S3, khoá bằng lockfile của S3 (`use_lockfile`, không cần DynamoDB). Yêu cầu Terraform >= 1.11.

### 1. Tạo bucket state (chỉ làm một lần cho mỗi account)

```bash
cd bootstrap
terraform init
terraform apply          # tạo bucket tfstate-<account-id>-ap-southeast-1
cd ..
```

Bucket có versioning, mã hoá SSE, chặn public và chỉ cho phép truy cập qua HTTPS. Thư mục `bootstrap/` dùng state local; file `bootstrap/terraform.tfstate` đã được `.gitignore`, nên giữ lại trên máy hoặc import lại khi cần.

### 2. Khởi tạo project chính với backend S3

```bash
terraform init                    # lần đầu
# hoặc, nếu trước đó đã có state local cần chuyển lên S3:
terraform init -migrate-state
```

Đổi account/region: sửa `bucket` và `region` trong `backend.tf` (tên bucket lấy từ output `state_bucket` của bootstrap).

## Biến

Sao chép `terraform.tfvars.example` thành `terraform.tfvars` và điền giá trị. File `*.tfvars` không được commit.
