# Jenkins: tài liệu kỹ thuật

Jenkins là công cụ CI của nền tảng DevOps trên EKS (`eks-cluster-ver1`). Nó build, test, quét chất lượng và bảo mật, rồi đẩy artifact và image lên Nexus.

| Hạng mục | Giá trị |
|---|---|
| Phiên bản | Jenkins **2.580.2 LTS** (JDK 21), chart `jenkins` 5.8.116 |
| URL | http://jenkins.gitlabonlinecom.click (ALB chung `alb-apps`) |
| Namespace | `jenkins` |
| Cài đặt | `helm upgrade --install jenkins ./helm-install/jenkins/jenkins -n jenkins` |
| Cấu hình | `helm-install/jenkins/jenkins/values.yaml` (Helm + JCasC, plugin ghim phiên bản) |
| Agent | Pod Kubernetes động, mỗi build một pod |

## Nội dung

1. [Kiến trúc và các tuỳ chọn cấu hình](01-kien-truc-va-cau-hinh.md): controller, agent động, plugin, JCasC, bảo mật, lưu trữ; ý nghĩa từng khoá cấu hình.
2. [Sizing theo mức tải](02-sizing.md): cấu hình cho tải thấp, tải vừa và enterprise; chỉ số cần theo dõi; vì sao controller dùng StatefulSet và cách scale khi nhiều job đồng thời (scale dọc + giảm tải cho controller, theo mô hình banking).
3. [Tích hợp, bảo mật và tuân thủ PCI DSS](03-tich-hop-va-bao-mat.md): tích hợp với GitLab, Nexus, SonarQube, Trivy, Argo CD, AWS; hiện trạng và lộ trình hardening; đối chiếu PCI DSS v4.0.1.
4. [So sánh với các công cụ CI/CD khác](04-so-sanh-cong-cu-ci-cd.md): GitLab CI, GitHub Actions, Tekton/Argo Workflows, AWS CodeBuild/CodePipeline, Azure DevOps.
5. [Hướng dẫn cấu hình đã triển khai](05-huong-dan-trien-khai.md): các bước cài, Secret, đăng nhập, kiểm tra, nâng cấp, sao lưu, sự cố đã gặp, artifact trên S3, mở rộng volume `JENKINS_HOME`, lưu trữ log build lên S3 (Object Lock 12 tháng).
6. [Vận hành và tự động hoá (enterprise)](06-van-hanh-va-tu-dong-hoa.md): mô hình vận hành, SLO, lịch định kỳ, quy trình nâng cấp an toàn, tự động hoá (image có sẵn plugin, Renovate, pipeline platform, cảnh báo bảo mật, Prometheus, sao lưu DLM, Shared Library, ApplicationSet), runbook sự cố, lộ trình áp dụng.
7. [Shared Library dùng chung (`ci-lib`)](07-shared-library.md): pipeline chuẩn cho Java/Spring Boot (Maven), Python, Node.js; tham số, contract với từng loại repo, chuẩn bị Jenkins/Nexus, quản lý phiên bản, bảo mật (trusted library, cổng Trivy/Quality Gate, waiver có hạn), chuyển `shopping-cart` sang thư viện. Mã nguồn: [`helm-install/jenkins/shared-library/`](../../helm-install/jenkins/shared-library/).
8. [Manifest sinh từ `helm template`](08-manifest-helm-template.md): danh sách tài nguyên Kubernetes thật sự được deploy (StatefulSet, Service, Ingress, PVC, ConfigMap JCasC, RBAC), giải thích từng container, volume, probe và nhận xét.
9. [Hạ tầng chạy build: Jenkins agent và GitLab Runner](../ci-agents/README.md): kiến trúc node group `ci_agents`, cơ chế đặt pod build, artifact và log build trên S3, GitLab Runner; hướng dẫn cài đặt đã thực hiện, kết quả kiểm tra, vận hành, sự cố đã gặp.

## Tóm tắt nhanh

- **Đang tốt:** core và plugin không còn cảnh báo bảo mật; plugin ghim phiên bản; cấu hình bằng code (JCasC); credentials lấy từ Kubernetes Secret; không chạy build trên controller; CSRF bật; container non-root.
- **Cần làm cho môi trường production / PCI DSS:** HTTPS (ACM), SSO + MFA, phân quyền theo vai trò, audit log lưu 12 tháng, NetworkPolicy, thay `docker:dind` privileged. Chi tiết ở [phần 3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening).
