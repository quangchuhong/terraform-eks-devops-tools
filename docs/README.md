# Tài liệu nền tảng DevOps trên EKS

Tài liệu cho các DevOps tool chạy trên cụm EKS `eks-cluster-ver1` (account `609320954321`, region `ap-southeast-1`). Tất cả app web dùng chung một ALB (Ingress group `alb-apps`) với tên miền `*.gitlabonlinecom.click`.

| Tool | Vai trò | Tài liệu |
|---|---|---|
| Jenkins | CI: build, test, quét chất lượng và bảo mật, đẩy artifact | [jenkins/](jenkins/README.md) |
| CI agents | Hạ tầng chạy build: node group `ci_agents` dùng chung cho Jenkins agent và GitLab Runner, artifact và log build trên S3 | [ci-agents/](ci-agents/README.md) |
| GitLab | Quản lý mã nguồn, GitOps repo | Đang viết |
| Nexus | Maven repository, Docker registry | Đang viết |
| SonarQube | Phân tích chất lượng mã, Quality Gate | Đang viết |
| Trivy | Quét lỗ hổng image | Đang viết |
| Argo CD | CD theo GitOps | Chưa triển khai |

Hướng dẫn cài nhanh các tool: [`helm-install/README.md`](../helm-install/README.md).
