# 3. Tích hợp với các DevOps tool khác, bảo mật và tuân thủ (PCI DSS)

[← Mục lục Nexus](README.md)

## 3.1. Bản đồ tích hợp

| Tích hợp | Hiện trạng | Cách cấu hình |
|---|---|---|
| **Jenkins (Maven)** | ✅ | `Jenkinsfile` tạo `.ci-settings.xml`: mirror `*` → `maven-public` (trong cụm), server `maven-releases`/`maven-snapshots`; credential `nexus-creds` (Secret `jenkins/nexus-ci`, user `ci-jenkins`) |
| **Jenkins (Docker)** | ✅ | `docker:dind` với `--insecure-registry=docker-internal.gitlabonlinecom.click`; push bằng credential `docker-user-internal` |
| **Shared Library `ci-lib`** | ✅ (mã nguồn) | Maven, PyPI (`PIP_INDEX_URL` + netrc), npm (`.ci-npmrc` + `${NPM_AUTH}`), xem [Jenkins 7](../jenkins/07-shared-library.md) |
| **GitLab Runner** | Có thể dùng | Biến CI/CD dạng masked (`NEXUS_USER`, `NEXUS_PASSWORD`), cấu hình như [phần 7](07-cau-hinh-theo-cong-nghe.md) |
| **Trivy** | ✅ | Trivy quét image tar trước khi push lên `docker-hosted` |
| **EKS (pull image ứng dụng)** | ⏸ Chưa | Registry HTTP: containerd trên node cần cấu hình mirror/insecure (`hosts.toml`), hoặc bật HTTPS (khuyến nghị). Xem [7.12](07-cau-hinh-theo-cong-nghe.md#712-dùng-nexus-làm-registry-cho-kubernetes) |
| **Argo CD / Helm** | ⏸ | Có thể thêm repo Helm hosted cho chart nội bộ |
| **AWS** | Chuẩn bị | IRSA `eks-nexus-role` (S3 `nexus-data-bucket-s3`, ECR) cho blob store S3 và proxy ECR |

### Nguyên tắc tích hợp

| Nguyên tắc | Áp dụng |
|---|---|
| Đọc qua group, ghi vào hosted | Client chỉ biết URL group; quyền ghi chỉ cấp trên repo hosted cần thiết |
| Không dùng `admin` cho máy | CI dùng `ci-jenkins` (role `ci-role`); máy build/lập trình viên dùng user có role `read-all` |
| Gọi trong cụm khi có thể | Pod dùng `nexus.nexus.svc.cluster.local:8081`, không vòng ra ALB |
| Secret không nằm trong file cấu hình | `settings.xml`, `.npmrc`, `pip` đọc mật khẩu từ biến môi trường hoặc file tạm ngoài workspace |
| Không ghi đè release | Repo release `allow_once` |

## 3.2. Hiện trạng bảo mật

| Hạng mục | Trạng thái | Ghi chú |
|---|---|---|
| Phiên bản | ✅ 3.85.0, không còn OrientDB | Theo dõi bản vá |
| Container | ✅ Non-root (uid 200) | Init container chạy root chỉ để chown |
| Mật khẩu admin | ✅ Ngẫu nhiên lúc cài | Đổi sau lần đầu; không dùng cho CI |
| Tài khoản CI | ✅ `ci-jenkins`, role tối thiểu, mật khẩu chỉ trong Secret, xoay vòng bằng `bootstrap.sh` | |
| Mã hoá đường truyền | ❌ HTTP (giao diện, Maven, npm, PyPI, Docker) | Docker client và containerd phải cấu hình insecure registry |
| Mã hoá khi lưu | ✅ EBS gp3 mã hoá | S3 (khi dùng): SSE-KMS |
| Anonymous | ⚠️ Cần kiểm tra | Nên tắt, hoặc chỉ cho đọc group không nhạy cảm |
| SSO | ⚠️ Chưa | CE hỗ trợ LDAP; SAML và User Token cần Pro |
| Sao lưu | ⚠️ Chưa có lịch | [6.4](06-van-hanh-va-tu-dong-hoa.md#64-sao-lưu-và-khôi-phục) |
| Kiểm soát nguồn thư viện | ⚠️ Proxy tải mọi thứ từ Internet | Quét ở pipeline (Trivy, SonarQube); Sonatype Firewall (trả phí) hoặc routing rule chặn package |
| Script API | ⚠️ `nexus.scripts.allowCreation=true` | Tắt khi không dùng Groovy script (giảm bề mặt tấn công) |

## 3.3. Lộ trình hardening

| # | Việc | Cách làm |
|---|---|---|
| 1 | **HTTPS** | ACM cho `*.gitlabonlinecom.click`, thêm HTTPS 443 + `certificate-arn` + `ssl-redirect` cho mọi Ingress trong group `alb-apps` (cả 3 Ingress Docker); bỏ `--insecure-registry` và cấu hình containerd insecure |
| 2 | **Anonymous** | Security → Anonymous Access: tắt; client nào cần đọc thì dùng user `read-all` |
| 3 | **Tắt Script API** | Bỏ `-Dnexus.scripts.allowCreation=true` và `nexus.scripts.allowCreation` nếu không dùng script |
| 4 | **LDAP** | Security → LDAP: kết nối AD/LDAP công ty, map group LDAP → role Nexus |
| 5 | **Role theo team** | Mỗi team một role ghi vào hosted của team (repo riêng hoặc content selector theo path, ví dụ `/com/bank/payments/**`) |
| 6 | **Routing rule** | Chặn package/namespace nguy hiểm hoặc chỉ cho phép namespace nội bộ ở proxy (Repository → Routing Rules), giảm rủi ro *dependency confusion* |
| 7 | **Sao lưu** | Task *Admin - Export databases for backup* hằng ngày + snapshot EBS/S3 versioning |
| 8 | **Cleanup + quota** | Cleanup policy mọi repo; blob store quota để cảnh báo trước khi đầy |
| 9 | **Log** | Đẩy `request.log`, `audit.log` (Pro) và `nexus.log` về CloudWatch, giữ 12 tháng |
| 10 | **Mạng** | Giới hạn IP truy cập ALB (WAF/SG) hoặc chỉ cho truy cập nội bộ/VPN |

## 3.4. Đối chiếu PCI DSS v4.0.1

| Yêu cầu | Nội dung | Hiện trạng | Việc cần làm |
|---|---|---|---|
| **1.2, 1.3** | Kiểm soát mạng | ⚠️ ALB public, HTTP | WAF/giới hạn IP, NetworkPolicy |
| **2.2** | Cấu hình an toàn | ⚠️ Script API bật, anonymous chưa rõ | Tắt Script API, tắt anonymous |
| **3.5** | Mã hoá dữ liệu lưu trữ | ✅ EBS mã hoá | S3 SSE-KMS khi chuyển blob |
| **4.2** | Mã hoá đường truyền | ❌ HTTP | HTTPS (ACM) |
| **6.3.2** | Kiểm kê thành phần phần mềm (SBOM) | ⚠️ Nexus biết component được dùng; chưa có SBOM | Trivy sinh SBOM (CycloneDX) ở pipeline, lưu kèm artifact |
| **6.3.3** | Vá lỗ hổng thành phần | ⚠️ | Quét dependency ở pipeline; chặn bản có lỗ hổng nghiêm trọng (routing rule/Firewall) |
| **7.2** | Phân quyền tối thiểu | ✅ CI có role riêng | Role theo team, rà soát định kỳ |
| **8.2, 8.3** | Định danh, xác thực | ⚠️ User nội bộ | LDAP/SSO |
| **8.4** | MFA | ❌ | MFA ở IdP (qua SAML, Pro) hoặc truy cập giao diện qua VPN có MFA |
| **8.6** | Tài khoản hệ thống | ⚠️ `ci-jenkins` mật khẩu dài, xoay vòng thủ công | Lịch xoay vòng (`bootstrap.sh` không truyền `ROTATE_CI_PASSWORD=no`), Pro: user token |
| **10.2, 10.5.1** | Log và lưu 12 tháng | ❌ | Log tập trung ≥ 12 tháng |
| **12.10** | Ứng phó sự cố | ⚠️ Runbook ([6.6](06-van-hanh-va-tu-dong-hoa.md#66-runbook-sự-cố)) | Diễn tập khôi phục |
