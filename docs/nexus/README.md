# Nexus Repository: tài liệu kỹ thuật

Nexus Repository là kho artifact tập trung của nền tảng DevOps trên EKS (`eks-cluster-ver1`): lưu thư viện và package nội bộ (jar, wheel, npm, conan...), image Docker, đồng thời làm **proxy có cache** cho các kho công khai (Maven Central, PyPI, npm, Docker Hub, kho gói Linux/Windows, công cụ của AWS/GCP/Azure). Build không phải ra Internet trực tiếp, nhanh hơn và kiểm soát được nguồn thư viện.

| Hạng mục | Giá trị |
|---|---|
| Phiên bản | Nexus Repository **3.85.0** (Community Edition), database nhúng **H2** |
| URL giao diện | http://nexus.gitlabonlinecom.click (ALB chung `alb-apps`, HTTP) |
| Docker registry | `docker.gitlabonlinecom.click` (pull: group), `docker-internal.gitlabonlinecom.click` (push: hosted), `docker-proxy.gitlabonlinecom.click` (Docker Hub cache) |
| Trong cụm | `http://nexus.nexus.svc.cluster.local:8081` |
| Namespace | `nexus` |
| Cài đặt | `helm upgrade --install nexus ./helm-install/nexus/nexus-repository-manager -n nexus` + `kubectl apply -f helm-install/nexus/manifests/` |
| Cấu hình repo | `helm-install/nexus/bootstrap.sh` (repo cho CI, user `ci-jenkins`), `helm-install/nexus/repos-extra.sh` (repo cho mọi công nghệ) |

## Nội dung

1. [Kiến trúc và các tuỳ chọn cấu hình](01-kien-truc-va-cau-hinh.md): loại repository (proxy, hosted, group), blob store, Docker connector, bảo mật, ý nghĩa từng khoá cấu hình.
2. [Sizing theo mức tải](02-sizing.md): cấu hình cho tải thấp, tải vừa và enterprise; dung lượng blob store; H2 và PostgreSQL; giới hạn của Community Edition; HA.
3. [Tích hợp, bảo mật và tuân thủ PCI DSS](03-tich-hop-va-bao-mat.md): tích hợp với Jenkins, GitLab Runner, Trivy, EKS; hiện trạng và lộ trình hardening; đối chiếu PCI DSS v4.0.1.
4. [So sánh với các kho artifact khác](04-so-sanh-cong-cu.md): JFrog Artifactory, Harbor, GitLab Package Registry, AWS CodeArtifact/ECR, GCP Artifact Registry, Azure Artifacts/ACR; **lưu Docker image trên Nexus so với ECR** (ưu nhược điểm, chi phí, khuyến nghị).
5. [Hướng dẫn cấu hình đã triển khai](05-huong-dan-trien-khai.md): cài đặt, Docker connector, bootstrap, kiểm tra, mở rộng dung lượng, nâng cấp, sao lưu, sự cố đã gặp.
6. [Vận hành và tự động hoá (enterprise)](06-van-hanh-va-tu-dong-hoa.md): lịch định kỳ, cleanup policy, task, sao lưu và khôi phục, giám sát, cấu hình bằng code, runbook.
7. [Cấu hình và sử dụng theo công nghệ](07-cau-hinh-theo-cong-nghe.md): **Docker proxy, Maven/Java/Gradle, Python, Node.js, C/C++ (Conan, vcpkg), Linux (apt, yum, apk), Windows (NuGet, Chocolatey, PowerShell), AWS, GCP, Azure**.
8. [Manifest sinh từ `helm template`](08-manifest-helm-template.md): Deployment, PVC, Service, Ingress của chart và Docker connector; giải thích cấu hình và nhận xét.

Liên quan: [Jenkins](../jenkins/README.md) (pipeline dùng Nexus), [Shared Library `ci-lib`](../jenkins/07-shared-library.md), [CI agents](../ci-agents/README.md).

## Tóm tắt nhanh

- **Đang tốt:** 3.85.0 không còn OrientDB (hết hỗ trợ, có CVE nghiêm trọng); container non-root (uid 200); mật khẩu admin ngẫu nhiên lúc cài; CI dùng user riêng `ci-jenkins` với role tối thiểu, mật khẩu chỉ nằm trong Secret; Maven, npm, PyPI, Docker có proxy/hosted/group; repo hosted dùng `allow_once` cho npm/PyPI (không ghi đè bản đã phát hành).
- **Cần làm cho môi trường production / PCI DSS:** HTTPS (ACM) cho giao diện và registry; tắt hoặc giới hạn anonymous; SSO (LDAP/SAML); blob store trên S3 hoặc PVC lớn hơn (đang 20Gi); sao lưu DB định kỳ; cleanup policy; chuyển H2 sang PostgreSQL khi tải lớn. Chi tiết ở [phần 3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening).
