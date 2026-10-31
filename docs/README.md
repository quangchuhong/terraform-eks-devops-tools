# Tài liệu nền tảng DevOps trên EKS

Tài liệu cho các DevOps tool chạy trên cụm EKS `eks-cluster-ver1` (account `609320954321`, region `ap-southeast-1`). Tất cả app web dùng chung một ALB (Ingress group `alb-apps`) với tên miền `*.gitlabonlinecom.click`.

| Tool | Vai trò | Tài liệu |
|---|---|---|
| Jenkins | CI: build, test, quét chất lượng và bảo mật, đẩy artifact | [jenkins/](jenkins/README.md) |
| CI agents | Hạ tầng chạy build: node group `ci_agents` dùng chung cho Jenkins agent và GitLab Runner, artifact và log build trên S3 | [ci-agents/](ci-agents/README.md) |
| GitLab | Quản lý mã nguồn, repo GitOps, GitLab CI | [gitlab/](gitlab/README.md) |
| Nexus | Kho artifact và proxy: Maven, npm, PyPI, NuGet, Docker, gói Linux/Windows, Conan, công cụ cloud | [nexus/](nexus/README.md) |
| SonarQube | Phân tích chất lượng mã, Quality Gate | Đang viết |
| Trivy | Quét lỗ hổng image, thư viện, IaC, secret, cụm Kubernetes; so sánh với Black Duck | [trivy/](trivy/README.md) |
| Argo CD | CD theo GitOps | Chưa triển khai |

Hướng dẫn cài nhanh các tool: [`helm-install/README.md`](../helm-install/README.md).

Xem và kiểm tra manifest Kubernetes thật sự được deploy (render bằng `helm template`, so sánh với cụm): [`helm-template/`](helm-template/README.md).
