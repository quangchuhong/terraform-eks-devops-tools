# GitLab: tài liệu kỹ thuật

GitLab là nơi quản lý mã nguồn của nền tảng DevOps trên EKS (`eks-cluster-ver1`): repo ứng dụng, repo GitOps, repo thư viện CI. Jenkins và GitLab Runner lấy mã từ đây để build.

| Hạng mục | Giá trị |
|---|---|
| Phiên bản | GitLab **19.5.3 CE**, chart `gitlab/gitlab` **10.5.4** |
| URL | http://gitlab.gitlabonlinecom.click (ALB chung `alb-apps`, HTTP) |
| Namespace | `gitlab` |
| Cài đặt | Terraform: `gitlab-helm.tf` (Helm release), `gitlab-backend.tf` (RDS, ElastiCache, S3, IAM, Secret) |
| Cấu hình | `helm-chart/gitlab-values.yaml` + giá trị hạ tầng do Terraform truyền vào |
| Dữ liệu | Repo Git: Gitaly (EBS gp3). Metadata: **RDS PostgreSQL 17**. Cache/queue: **ElastiCache Redis 7** (TLS). File (LFS, artifact, package, registry, backup): **S3** qua IRSA |

## Nội dung

1. [Kiến trúc và các tuỳ chọn cấu hình](01-kien-truc-va-cau-hinh.md): các thành phần (webservice, sidekiq, gitaly, gitlab-shell, registry, kas, toolbox), dịch vụ AWS bên ngoài, luồng request, ý nghĩa từng nhóm cấu hình.
2. [Sizing theo mức tải](02-sizing.md): cấu hình cho tải thấp, tải vừa và enterprise; cách scale từng thành phần; Gitaly và tính sẵn sàng; chỉ số cần theo dõi.
3. [Tích hợp, bảo mật và tuân thủ PCI DSS](03-tich-hop-va-bao-mat.md): tích hợp với Jenkins, GitLab Runner, Argo CD, Nexus, SonarQube, AWS; hiện trạng và lộ trình hardening; đối chiếu PCI DSS v4.0.1.
4. [So sánh với các nền tảng quản lý mã nguồn khác](04-so-sanh-cong-cu-scm.md): GitHub Enterprise, Bitbucket Data Center, Azure DevOps Server, Gitea/Forgejo, AWS CodeCommit; CE so với Premium/Ultimate.
5. [Hướng dẫn cấu hình đã triển khai](05-huong-dan-trien-khai.md): các bước cài bằng Terraform, đăng nhập, cấu hình ban đầu, group/project/token cho CI, kiểm tra, nâng cấp, sao lưu, sự cố đã gặp.
6. [Vận hành và tự động hoá (enterprise)](06-van-hanh-va-tu-dong-hoa.md): mô hình vận hành, SLO, lịch định kỳ, nâng cấp theo upgrade path, sao lưu và khôi phục, giám sát, quản lý group/project bằng code, dọn dẹp, runbook sự cố, lộ trình áp dụng.

Liên quan: [GitLab Runner và hạ tầng chạy build](../ci-agents/README.md), [Jenkins](../jenkins/README.md).

## Tóm tắt nhanh

- **Đang tốt:** không còn PostgreSQL/Redis/MinIO chạy trong cụm (dùng RDS, ElastiCache, S3 do AWS quản lý); dữ liệu mã hoá khi lưu (RDS, ElastiCache, S3, EBS); Redis mã hoá đường truyền và có mật khẩu; S3 truy cập bằng IAM role (IRSA), không có access key; mật khẩu sinh ngẫu nhiên và nằm trong Kubernetes Secret; cấu hình bằng code (Terraform + values).
- **Cần làm cho môi trường production / PCI DSS:** HTTPS (ACM), SSO + bắt buộc 2FA, tắt đăng ký tự do, RDS Multi-AZ + deletion protection + backup dài hơn, sao lưu GitLab định kỳ (kèm `gitlab-rails-secret`), log/audit lưu 12 tháng, node và RDS ở subnet private. Chi tiết ở [phần 3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening).
