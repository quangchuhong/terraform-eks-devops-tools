# 3. Tích hợp với các DevOps tool khác, bảo mật và tuân thủ (PCI DSS)

[← Mục lục GitLab](README.md)

## 3.1. Bản đồ tích hợp

```
 Lập trình viên ──HTTP (token)──► GitLab ◄──── mirror từ GitHub (git push gitlab)
                                    │
     ┌──────────────────────────────┼──────────────────────────────┬──────────────────────────┐
     ▼                              ▼                              ▼                          ▼
 Jenkins (Multibranch)       GitLab Runner                   Argo CD (dự kiến)         SonarQube (dự kiến)
 clone qua HTTP, token       nhận job CI của GitLab,         đọc repo GitOps            đăng nhập/import
 Group Access Token          chạy pod trên node CI           (read-only token)          project từ GitLab
 (credential gitlab-         (glrt- token)
 token-dev-group)
     │                              │
     ▼                              ▼
 Nexus / SonarQube / Trivy    Nexus, Container Registry của GitLab

 GitLab ──► AWS: RDS (metadata), ElastiCache (cache, hàng đợi), S3 (file, registry, backup) qua IRSA; Route 53, ALB
```

| Tích hợp | Hiện trạng | Cách cấu hình |
|---|---|---|
| **Jenkins** | ✅ Đang dùng | Plugin `gitlab-branch-source` + `gitlab-api`. Job Multibranch `shopping-cart` quét `devops/ci-cd/shopping-cart`. Credential `gitlab-token-dev-group` lấy từ Secret `jenkins/gitlab-ci` (Group Access Token của group `devops`, scope `read_api`, `read_repository`) |
| **GitLab Runner** | ✅ Đang dùng | Instance runner, tags `eks,k8s`, pod job trên node group CI ([CI agents](../ci-agents/README.md)) |
| **GitHub** (nguồn gốc mã app) | ✅ | Repo app có hai remote `origin` (GitHub) và `gitlab`; đẩy lên GitLab bằng `git push gitlab <nhánh>`. Có thể thay bằng **Pull mirroring** của GitLab (Premium) hoặc push mirror từ GitHub Actions |
| **Argo CD** | ⏸ Dự kiến | Repo `devops/ci-cd/gitops-shopping-cart`; Argo CD dùng Project/Deploy Token chỉ đọc (`read_repository`) |
| **SonarQube** | ⏸ Tuỳ chọn | Khai báo GitLab làm ALM (DevOps Platform Integration) để import project và đăng nhập bằng GitLab OAuth; trang trí MR cần bản Developer trở lên |
| **Nexus** | Gián tiếp | Pipeline (Jenkins/GitLab CI) đẩy artifact và image lên Nexus. GitLab Package Registry và Container Registry cũng sẵn có nếu muốn gom về một chỗ |
| **Webhook** | Tuỳ chọn | GitLab → Jenkins (`/project/...` hoặc `gitlab-branch-source` tự tạo webhook) để build ngay khi push thay vì chờ quét định kỳ |
| **AWS** | ✅ | IRSA role `eks-cluster-ver1-gitlab-s3` cho mọi service account trong namespace `gitlab` |

### Nguyên tắc tích hợp

| Nguyên tắc | Áp dụng |
|---|---|
| Không dùng tài khoản người thật cho máy | Jenkins, Argo CD, Runner dùng Group/Project Access Token, Deploy Token hoặc runner token, không dùng PAT của `root` hay của nhân viên |
| Quyền tối thiểu | Token CI chỉ `read_repository` (+ `read_api` cho Branch Source). Token ghi (cập nhật GitOps) tách riêng, giới hạn đúng project |
| Token có hạn | Đặt ngày hết hạn (tối đa 1 năm theo mặc định GitLab), xoay vòng định kỳ |
| Token tạo đúng phạm vi | Token tạo ở group nào chỉ thấy project của group đó. Đã gặp: token tạo ở `dev` không đọc được `devops/ci-cd/shopping-cart` (`HTTP Basic: Access denied`) |
| Secret không nằm trong Git | Token lưu trong Kubernetes Secret, nhập bằng `read -s`; repo hạ tầng là public và có GitHub push protection |

## 3.2. Hiện trạng bảo mật

| Hạng mục | Trạng thái | Ghi chú |
|---|---|---|
| Phiên bản | ✅ GitLab 19.5.3 (bản vá mới nhất của 19.5 lúc cài) | Theo dõi security release hằng tháng |
| Mã hoá khi lưu | ✅ RDS, ElastiCache, EBS (Gitaly), S3 | S3 đang dùng SSE-S3 (AES256); RDS dùng key mặc định `aws/rds` |
| Mã hoá đường truyền | ⚠️ Redis: TLS. Người dùng → ALB: **HTTP**. GitLab → RDS: chưa ép `sslmode=require` | HTTPS là việc ưu tiên số 1 |
| Thông tin xác thực dịch vụ | ✅ Mật khẩu DB/Redis sinh ngẫu nhiên 32 ký tự, nằm trong Secret; S3 qua IRSA, không access key | Mật khẩu vẫn nằm trong Terraform state (state trên S3 có mã hoá) |
| Mạng | ⚠️ RDS/Redis chỉ nhận kết nối từ security group node/cluster, không public. Node EKS ở **subnet public** (default VPC) | Production: subnet private + NAT, VPC endpoint cho S3 |
| Xác thực người dùng | ⚠️ Tài khoản nội bộ GitLab, chưa SSO, chưa bắt buộc 2FA | |
| Đăng ký tài khoản | ⚠️ Cần kiểm tra và **tắt Sign-up** (mặc định bật) | Admin → Settings → General → Sign-up restrictions |
| Tài khoản `root` | ⚠️ Mật khẩu ban đầu nằm trong Secret `gitlab-gitlab-initial-root-password` | Đổi mật khẩu, bật 2FA cho `root`, tạo admin có tên riêng, hạn chế dùng `root` |
| Sao lưu | ⚠️ RDS backup 7 ngày; chưa có lịch `backup-utility`; chưa sao lưu `gitlab-rails-secret` | [6.5](06-van-hanh-va-tu-dong-hoa.md#65-sao-lưu-và-khôi-phục) |
| Chống xoá nhầm | ⚠️ `gitlab_db_deletion_protection = false`, S3 không versioning | Bật cho môi trường thật |
| Audit log | ⚠️ CE chỉ có log ứng dụng (pod), không có Audit Events đầy đủ | Đẩy log pod về CloudWatch/OpenSearch, giữ 12 tháng; Audit Events đầy đủ cần Premium |
| Bài học | ⚠️ Repo hạ tầng public từng bị GitHub push protection chặn vì có secret trong commit | Không commit secret; giữ push protection; repo hạ tầng nên để private |

## 3.3. Lộ trình hardening

Thứ tự gợi ý (việc trên quan trọng hơn):

| # | Việc | Cách làm | Ghi chú |
|---|---|---|---|
| 1 | **HTTPS** | Chứng chỉ ACM cho `*.gitlabonlinecom.click`; trên **mọi** Ingress của group `alb-apps`: `listen-ports: [{"HTTP":80},{"HTTPS":443}]`, `certificate-arn`, `ssl-redirect: "443"`; `global.hosts.https: true` | Làm đồng loạt cho cả group ALB (annotation phải giống nhau). Cập nhật URL trong Jenkins, Runner, remote git |
| 2 | **Tắt đăng ký, bảo vệ `root`** | Tắt Sign-up; đổi mật khẩu `root`; tạo admin có tên riêng; bật 2FA | Làm ngay sau khi cài |
| 3 | **SSO + 2FA bắt buộc** | OmniAuth SAML/OIDC với IdP công ty (CE hỗ trợ đăng nhập SAML/OIDC, LDAP); Admin → Settings → General → Sign-in restrictions → *Enforce two-factor authentication* | Đồng bộ group từ IdP (SAML Group Sync) cần Premium |
| 4 | **Chính sách repo** | Protected branches (`main`, `release/*`: chỉ Maintainer merge, không ai push trực tiếp), protected tags, bắt buộc MR; CODEOWNERS | Bắt buộc số người duyệt và CODEOWNERS approval cần Premium; với CE dùng quy ước + protected branch |
| 5 | **Visibility mặc định** | Admin → Settings → General → Visibility: mặc định `Private`, hạn chế `Public` | Tránh lộ mã nguồn |
| 6 | **Sao lưu đầy đủ** | Lịch `backup-utility` lên S3, sao lưu `gitlab-rails-secret`, kiểm tra khôi phục định kỳ | [6.5](06-van-hanh-va-tu-dong-hoa.md#65-sao-lưu-và-khôi-phục) |
| 7 | **Dữ liệu** | RDS Multi-AZ + deletion protection + backup 35 ngày + `sslmode=require`; Redis failover; S3 dùng SSE-KMS (CMK) + versioning cho bucket `backups` | Đổi biến Terraform và `gitlab-backend.tf` |
| 8 | **Mạng** | Node và RDS ở subnet private; VPC endpoint S3; giới hạn IP truy cập ALB (security group hoặc WAF) hoặc ALB internal + VPN | Thay đổi lớn, lên kế hoạch riêng |
| 9 | **Log và audit** | Fluent Bit đẩy log pod `gitlab` (đặc biệt `production_json.log`, `api_json.log`, `audit_json.log`) về CloudWatch Logs, giữ ≥ 12 tháng | Đáp ứng PCI DSS 10 |
| 10 | **NetworkPolicy** | Chỉ cho phép pod trong namespace `gitlab` gọi Gitaly, chỉ ALB gọi webservice | Cần CNI hỗ trợ NetworkPolicy (VPC CNI bật network policy) |
| 11 | **SSH (tuỳ chọn)** | NLB riêng cho cổng 22 tới `gitlab-shell` (`gitlab.gitlab-shell.service.type: LoadBalancer` + annotation NLB) | Chỉ bật nếu cần; HTTP + token là đủ cho CI |
| 12 | **Quét bảo mật trong GitLab CI** | Template SAST, Secret Detection, Dependency Scanning, Container Scanning (có trong Free, dashboard tổng hợp cần Ultimate) | Bổ sung cho SonarQube/Trivy trong Jenkins |

## 3.4. Đối chiếu PCI DSS v4.0.1

Ký hiệu: ✅ đạt, ⚠️ một phần, ❌ chưa đạt.

| Yêu cầu | Nội dung | Hiện trạng | Việc cần làm |
|---|---|---|---|
| **1.2, 1.3** – Kiểm soát mạng | Giới hạn truy cập vào/ra hệ thống | ⚠️ RDS/Redis chỉ mở cho SG node; ALB public, node ở subnet public | Subnet private, WAF/giới hạn IP, NetworkPolicy |
| **2.2** – Cấu hình an toàn | Tắt thành phần thừa, đổi mặc định | ⚠️ Đã tắt Pages, Mattermost, NGINX, Prometheus, Runner đi kèm; còn Sign-up, `root` | Tắt Sign-up, bảo vệ `root`, gỡ hostname thừa (`minio`) khỏi `app_hostnames` |
| **3.5** – Bảo vệ dữ liệu lưu trữ | Mã hoá dữ liệu nhạy cảm | ✅ RDS, Redis, EBS, S3 mã hoá; secret CI mã hoá bằng `gitlab-rails-secret` | Dùng KMS CMK cho S3/RDS; sao lưu và bảo vệ `gitlab-rails-secret` |
| **4.2** – Mã hoá đường truyền | TLS cho dữ liệu đi qua mạng | ❌ Người dùng ↔ ALB là HTTP; ⚠️ GitLab ↔ RDS chưa ép TLS; ✅ Redis TLS | HTTPS (ACM), `sslmode=require` |
| **6.2, 6.3** – Phát triển an toàn, vá lỗi | Review mã, vá bảo mật kịp thời | ⚠️ Có MR và protected branch; cập nhật GitLab thủ công | Bắt buộc MR + duyệt; lịch vá hằng tháng ([6.3](06-van-hanh-va-tu-dong-hoa.md#63-nâng-cấp-theo-upgrade-path)) |
| **6.4** – Bảo vệ ứng dụng web công khai | WAF hoặc đánh giá định kỳ | ❌ | AWS WAF trước ALB (managed rules) |
| **7.2** – Phân quyền theo nhu cầu | Quyền tối thiểu | ⚠️ Role GitLab (Guest/Reporter/Developer/Maintainer/Owner) theo group; token CI scope tối thiểu | Rà soát thành viên group định kỳ; đồng bộ từ IdP |
| **8.2, 8.3** – Định danh và xác thực | Tài khoản riêng, mật khẩu mạnh | ⚠️ Tài khoản nội bộ | SSO; chính sách mật khẩu; khoá tài khoản không dùng |
| **8.4** – MFA | MFA cho mọi truy cập vào CDE | ❌ | Bắt buộc 2FA hoặc MFA ở IdP |
| **8.6** – Tài khoản hệ thống | Quản lý tài khoản/ token cho ứng dụng | ⚠️ Group Access Token, runner token trong Secret | Ngày hết hạn, xoay vòng, kiểm kê token |
| **10.2** – Ghi log sự kiện | Log truy cập và thao tác quản trị | ⚠️ Log ứng dụng có trong pod; CE thiếu Audit Events đầy đủ | Thu log tập trung; cân nhắc Premium |
| **10.5.1** – Lưu log 12 tháng | 3 tháng truy xuất ngay | ❌ Log pod mất khi pod bị thay | CloudWatch Logs/S3 có retention ≥ 12 tháng |
| **11.3** – Quét lỗ hổng | Quét nội bộ/ngoài định kỳ | ⚠️ Chưa quét image GitLab định kỳ | Trivy quét image GitLab mỗi lần nâng cấp; quét ngoài hằng quý |
| **12.10** – Ứng phó sự cố | Quy trình xử lý sự cố | ⚠️ Có runbook ([6.6](06-van-hanh-va-tu-dong-hoa.md#66-runbook-sự-cố)) | Diễn tập khôi phục định kỳ |

**Ưu tiên tối thiểu nếu GitLab nằm trong phạm vi CDE:** HTTPS (4.2) → tắt Sign-up, 2FA/SSO (8.3, 8.4) → sao lưu + kiểm tra khôi phục → log tập trung 12 tháng (10.x) → mạng private + WAF (1.x, 6.4).
