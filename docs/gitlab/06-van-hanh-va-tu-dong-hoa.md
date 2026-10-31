# 6. Vận hành và tự động hoá GitLab (enterprise)

[← Mục lục GitLab](README.md)

Phần này là hướng dẫn vận hành GitLab self-managed trên EKS theo mô hình doanh nghiệp (ngân hàng): ai làm gì, làm định kỳ những gì, nâng cấp và sao lưu thế nào, tự động hoá phần nào.

## 6.1. Mô hình vận hành

### Nguyên tắc

| Nguyên tắc | Áp dụng |
|---|---|
| Hạ tầng và cấu hình là code | Mọi thay đổi chart/values/RDS/S3 qua Terraform + MR, không sửa tay trên cụm hay Console |
| Cấu hình ứng dụng là code | Group, project, quyền, protected branch, cài đặt instance quản lý bằng Terraform provider `gitlabhq/gitlab` ([6.4.3](#643-group-project-và-quyền-bằng-code)) |
| Dữ liệu tách khỏi cụm | Metadata trên RDS, file trên S3; chỉ Gitaly còn dữ liệu trên EBS |
| Nâng cấp nhỏ, đều đặn | Bản vá mỗi tháng; không để tụt quá nhiều bản (upgrade path dài, rủi ro cao) |
| Sao lưu phải khôi phục được | Mỗi quý diễn tập khôi phục ra môi trường thử |

### Vai trò

| Vai trò | Trách nhiệm |
|---|---|
| Platform/DevOps team | Cài đặt, nâng cấp, sao lưu, giám sát, xử lý sự cố GitLab và Runner |
| Security team | Duyệt chính sách (SSO, 2FA, token), rà soát quyền, theo dõi security release, audit |
| Group Owner (mỗi team) | Quản lý thành viên group, protected branch, token của project |
| DBA / Cloud team | RDS, ElastiCache, backup, Multi-AZ |

### Mục tiêu dịch vụ (SLO gợi ý)

| Chỉ số | Mục tiêu |
|---|---|
| Khả dụng (giao diện + Git HTTP) | 99,5%/tháng (lab), 99,9% (production có Multi-AZ) |
| Độ trễ trang p95 | < 2 giây |
| Độ trễ job Sidekiq | < 1 phút |
| RPO (mất dữ liệu tối đa) | 24 giờ (backup hằng ngày); 5 phút cho DB (RDS point-in-time) |
| RTO (thời gian khôi phục) | 4 giờ |

## 6.2. Lịch vận hành định kỳ

| Tần suất | Việc |
|---|---|
| **Hằng ngày** | Backup tự động (`backup-utility`) và kiểm tra job thành công; xem pod lỗi, cảnh báo |
| **Hằng tuần** | Xem dung lượng PVC Gitaly, RDS storage, bucket `registry`/`artifacts`; xem Admin → Monitoring → Health check, Background migrations |
| **Hằng tháng** | Áp dụng bản vá bảo mật (GitLab phát hành bản vá thường vào tuần thứ 2 và thứ 4); rà soát token sắp hết hạn; xoá user nghỉ việc |
| **Hằng quý** | Diễn tập khôi phục; rà soát thành viên group và quyền admin; kiểm tra cấu hình Sign-up, 2FA, visibility |
| **Hằng năm** | Nâng major theo upgrade path; xoay vòng secret hạ tầng (mật khẩu RDS, Redis AUTH); đánh giá lại sizing |

## 6.3. Nâng cấp theo upgrade path

### Quy trình chuẩn

1. **Đọc release notes** của các bản sẽ đi qua (GitLab và chart), đặc biệt mục *Upgrade notes*, *Breaking changes*, yêu cầu PostgreSQL/Redis.
2. **Xác định các bản dừng bắt buộc** bằng GitLab Upgrade Path tool (from: bản hiện tại, to: bản đích).
3. **Kiểm tra trước:**
   ```bash
   kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rake gitlab:check SANITIZE=true
   kubectl -n gitlab exec deploy/gitlab-toolbox -- gitlab-rails runner 'puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'
   ```
   Lệnh thứ hai phải ra `0` (không còn background migration đang chờ). Có thể xem tương tự ở Admin → Monitoring → Background migrations.
4. **Sao lưu:** `backup-utility`, snapshot RDS thủ công, snapshot EBS Gitaly ([6.5](#65-sao-lưu-và-khôi-phục)).
5. **Nâng từng bản dừng:** đổi `gitlab_chart_version`, `terraform plan` (chỉ `helm_release.gitlab` update in-place), `terraform apply`, theo dõi `kubectl -n gitlab get pods -w` và Job `gitlab-migrations-*` → `Completed`.
6. **Kiểm tra sau mỗi bước:** đăng nhập, clone/push, Jenkins quét Multibranch, một job GitLab Runner; background migrations về 0 rồi mới đi bước tiếp.
7. **Rollback:** GitLab **không hỗ trợ hạ phiên bản** khi migration đã chạy. Rollback = khôi phục snapshot RDS + EBS Gitaly và cài lại phiên bản cũ. Vì vậy bước 4 là bắt buộc.

Bản vá cùng minor (ví dụ 19.5.3 → 19.5.5) chỉ cần bước 1, 4 (snapshot RDS), 5 và 6.

### Tự động hoá phát hiện phiên bản mới

- **Renovate** trên repo hạ tầng theo dõi chart `gitlab` trong `variables.tf` (custom regex manager), tự tạo MR khi có bản vá; pipeline của MR chạy `terraform plan` để xem trước.
- Đăng ký kênh security release của GitLab (RSS hoặc email) và đưa vào quy trình tiếp nhận lỗ hổng.

## 6.4. Tự động hoá

### 6.4.1. Sao lưu định kỳ

Chart có sẵn CronJob sao lưu trong toolbox. Thêm vào `helm-chart/gitlab-values.yaml`:

```yaml
gitlab:
  toolbox:
    backups:
      cron:
        enabled: true
        schedule: "0 18 * * *"          # 01:00 giờ Việt Nam
        extraArgs: "--s3tool awscli --skip registry,artifacts,lfs,packages,uploads"
        persistence:
          enabled: true
          storageClass: gp3
          size: 50Gi                   # chỗ tạm để nén backup (≥ dung lượng repo + DB dump)
```

- `--skip registry,artifacts,...`: các file này **đã nằm trên S3**, sao lưu bằng S3 versioning/replication thay vì chép lại vào tarball (tiết kiệm thời gian và dung lượng). Backup khi đó gồm DB và repo.
- Bucket `gitlab-609320954321-backups` nên bật versioning + lifecycle (ví dụ giữ 35 ngày) + Object Lock nếu cần bất biến.

### 6.4.2. Sao lưu secret của chart

`backup-utility` **không** sao lưu Kubernetes Secret. Thiếu `gitlab-rails-secret` thì bản backup không giải mã được biến CI/CD, runner token, 2FA. Sao lưu sang AWS Secrets Manager mỗi khi cài mới hoặc đổi secret:

```bash
kubectl -n gitlab get secret gitlab-rails-secret -o jsonpath='{.data.secrets\.yml}' | base64 -d > /tmp/gitlab-rails-secret.yml
aws secretsmanager create-secret --name gitlab/rails-secret --secret-string file:///tmp/gitlab-rails-secret.yml --region ap-southeast-1
rm -f /tmp/gitlab-rails-secret.yml
```

Lần sau dùng `put-secret-value` thay cho `create-secret`. Làm tương tự với `gitlab-gitaly-secret`, `gitlab-gitlab-shell-secret`, `gitlab-registry-secret`, `gitlab-gitlab-workhorse-secret`, `gitlab-gitlab-kas-secret` nếu muốn khôi phục y nguyên.

### 6.4.3. Group, project và quyền bằng code

Terraform provider `gitlabhq/gitlab` quản lý cấu hình bên trong GitLab, đặt ở một thư mục Terraform riêng (ví dụ `gitlab-config/`), chạy sau khi GitLab đã lên:

```hcl
terraform {
  required_providers {
    gitlab = { source = "gitlabhq/gitlab" }
  }
}

provider "gitlab" {
  base_url = "http://gitlab.gitlabonlinecom.click/api/v4/"
  # token đọc từ biến môi trường GITLAB_TOKEN (PAT của admin dành cho automation)
}

resource "gitlab_application_settings" "this" {
  signup_enabled                    = false
  require_two_factor_authentication = true
  default_project_visibility        = "private"
  default_group_visibility          = "private"
}

resource "gitlab_group" "devops" {
  name             = "devops"
  path             = "devops"
  visibility_level = "private"
}

resource "gitlab_group" "ci_cd" {
  name      = "ci-cd"
  path      = "ci-cd"
  parent_id = gitlab_group.devops.id
}

resource "gitlab_project" "shopping_cart" {
  name             = "shopping-cart"
  namespace_id     = gitlab_group.ci_cd.id
  visibility_level = "private"
}

resource "gitlab_branch_protection" "main" {
  project            = gitlab_project.shopping_cart.id
  branch             = "main"
  push_access_level  = "no one"
  merge_access_level = "maintainer"
}
```

Lợi ích: mọi thay đổi quyền và chính sách đi qua MR (có người duyệt, có lịch sử), dễ kiểm toán. Thêm team mới bằng cách thêm một khối `gitlab_group` + `gitlab_group_membership` (hoặc đồng bộ từ IdP).

### 6.4.4. Giám sát và cảnh báo

| Nguồn | Cách lấy | Cảnh báo gợi ý |
|---|---|---|
| Pod GitLab | `kube-prometheus-stack` + ServiceMonitor cho `gitlab-exporter`, webservice (`/-/metrics`), sidekiq, gitaly | Pod restart liên tục, HPA chạm max, Sidekiq queue latency > 1 phút |
| Health | `/-/readiness`, `/-/liveness` (chỉ gọi được từ IP trong *monitoring allowlist*) | Readiness lỗi > 5 phút |
| ALB | CloudWatch `HTTPCode_Target_5XX_Count`, `TargetResponseTime` | 5xx > 1%, p95 > 2 giây |
| RDS | CloudWatch `CPUUtilization`, `FreeStorageSpace`, `DatabaseConnections` | CPU > 70%, storage < 20% |
| ElastiCache | `DatabaseMemoryUsagePercentage`, `Evictions` | Memory > 75%, có eviction |
| PVC Gitaly | `kubelet_volume_stats_*` | > 80% |
| Backup | Trạng thái CronJob toolbox, object mới trong bucket backups | Không có backup mới trong 26 giờ |

### 6.4.5. Dọn dẹp tự động

| Việc | Cấu hình |
|---|---|
| Image cũ trong Container Registry | Project → Settings → Packages and registries → **Cleanup policies** (giữ N tag gần nhất, xoá tag cũ hơn X ngày); chạy garbage collection registry định kỳ |
| Artifact CI | Admin → Settings → CI/CD → *Default artifacts expiration* (ví dụ 30 ngày); trong `.gitlab-ci.yml` dùng `expire_in` |
| Pipeline cũ | Project → Settings → CI/CD → *Automatic pipeline cleanup* (xoá pipeline cũ hơn X ngày) |
| Repo | Gitaly housekeeping tự động (`git gc`, repack); Admin → Settings → Repository → Housekeeping |
| User không hoạt động | Admin → Settings → General → *Dormant users* (tự vô hiệu hoá sau N ngày) |
| Bucket `tmp` | S3 lifecycle xoá object sau 7 ngày |

## 6.5. Sao lưu và khôi phục

### Thành phần cần sao lưu

| Thành phần | Cách | Tần suất | Giữ |
|---|---|---|---|
| DB + repo (tarball ứng dụng) | `backup-utility` (CronJob toolbox) → S3 `-backups` | Hằng ngày | 35 ngày |
| Database | RDS automated backup (point-in-time) | Liên tục | 7 ngày (production: 35) |
| Repo Git | Snapshot EBS PVC Gitaly (AWS Backup/DLM) | Hằng ngày | 7–30 bản |
| File (artifacts, lfs, uploads, packages, registry) | S3 versioning (+ Cross-Region Replication cho DR) | Liên tục | Theo lifecycle |
| Secret của chart | Secrets Manager ([6.4.2](#642-sao-lưu-secret-của-chart)) | Khi thay đổi | Vĩnh viễn |
| Cấu hình | Git (repo hạ tầng) + Terraform state trên S3 | Mỗi thay đổi | — |

### Khôi phục từ bản backup ứng dụng

Áp dụng khi mất dữ liệu ứng dụng (xoá nhầm project, DB hỏng) hoặc chuyển sang cụm mới.

1. Cài GitLab **cùng phiên bản** với bản backup (tên file có phiên bản, ví dụ `..._19.5.3_gitlab_backup.tar`).
2. Khôi phục secret: ghi đè `gitlab-rails-secret` bằng bản trong Secrets Manager, rồi khởi động lại webservice, sidekiq, toolbox.
   ```bash
   aws secretsmanager get-secret-value --secret-id gitlab/rails-secret --query SecretString --output text --region ap-southeast-1 > /tmp/secrets.yml
   kubectl -n gitlab create secret generic gitlab-rails-secret --from-file=secrets.yml=/tmp/secrets.yml --dry-run=client -o yaml | kubectl apply -f -
   rm -f /tmp/secrets.yml
   kubectl -n gitlab rollout restart deploy/gitlab-webservice-default deploy/gitlab-sidekiq-all-in-1-v2 deploy/gitlab-toolbox
   ```
3. Tạm dừng các thành phần ghi dữ liệu:
   ```bash
   kubectl -n gitlab scale deploy -l app=webservice --replicas=0
   kubectl -n gitlab scale deploy -l app=sidekiq --replicas=0
   ```
4. Khôi phục (tên file lấy từ `aws s3 ls s3://gitlab-609320954321-backups/`, bỏ đuôi `_gitlab_backup.tar`):
   ```bash
   kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility --restore -t <timestamp>_<ngày>_19.5.3 --s3tool awscli
   ```
5. Bật lại: `kubectl -n gitlab scale deploy -l app=webservice --replicas=2` và tương tự cho sidekiq (HPA sẽ điều chỉnh tiếp).
6. Kiểm tra: `gitlab-rake gitlab:check SANITIZE=true`, `gitlab-rake gitlab:doctor:secrets` (kiểm tra giải mã được dữ liệu), đăng nhập, clone, chạy pipeline.

### Khôi phục nhanh từng phần

| Tình huống | Cách nhanh nhất |
|---|---|
| DB hỏng hoặc xoá nhầm dữ liệu trong vài ngày gần đây | RDS point-in-time restore ra instance mới, đổi endpoint (`global.psql.host` qua Terraform) |
| Volume Gitaly hỏng | Tạo volume từ snapshot EBS, gắn vào PVC `repo-data-gitlab-gitaly-0` (quy trình như [Jenkins 5.9](../jenkins/05-huong-dan-trien-khai.md#khôi-phục-rollback-từ-snapshot), thay namespace và tên PVC) |
| Xoá nhầm một project | Project xoá có thời gian chờ (*delayed project deletion*, mặc định 7 ngày): Admin → Projects → Restore |

## 6.6. Runbook sự cố

| Tình huống | Kiểm tra | Xử lý |
|---|---|---|
| **Giao diện 502/503** | `kubectl -n gitlab get pods`; Ingress `kubectl -n gitlab get ingress` | webservice chưa Ready: xem `kubectl -n gitlab logs deploy/gitlab-webservice-default -c webservice --tail=50`; lỗi DB/Redis: kiểm tra RDS/ElastiCache |
| **Không kết nối được DB** (`PG::ConnectionBad`) | Trạng thái RDS trên Console; security group `eks-cluster-ver1-gitlab-data` | RDS đang bảo trì/khởi động lại: chờ; mật khẩu đổi ngoài Terraform: đồng bộ Secret `gitlab-postgresql-password` |
| **Lỗi Redis** (`Redis::CannotConnectError`) | Trạng thái ElastiCache | Kiểm tra `scheme: rediss` và AUTH token khớp Secret `gitlab-redis-secret` |
| **Clone/push lỗi, trang project 500** | `kubectl -n gitlab logs gitlab-gitaly-0 --tail=50`; `kubectl -n gitlab get pod gitlab-gitaly-0 -o wide` | Gitaly `Pending` vì `volume node affinity conflict`: thiếu node ở AZ của volume (giữ `min_size = 3`); PVC đầy: mở rộng ([2.4](02-sizing.md#24-mở-rộng-ổ-gitaly-khi-gần-đầy)) |
| **Pipeline/mirror/email chậm** | Admin → Monitoring → Background jobs (Sidekiq) | Tăng `maxReplicas` sidekiq; tìm job lỗi lặp lại |
| **Upload/tải artifact lỗi** | Log webservice/workhorse có `AccessDenied` S3 | Kiểm tra annotation IRSA trên service account, policy role `eks-cluster-ver1-gitlab-s3`, tên bucket |
| **`HTTP Basic: Access denied`** | Token còn hạn? Scope? Tạo ở group nào? | Tạo lại token đúng group và scope, cập nhật Secret nơi dùng |
| **Migrations Job lỗi khi nâng cấp** | `kubectl -n gitlab logs job/gitlab-migrations-<id>` | Không nâng tiếp; sửa nguyên nhân (thường là bỏ qua bản dừng bắt buộc, DB cũ); nếu cần thì khôi phục snapshot |
| **Mất `gitlab-rails-secret`** | `gitlab-rake gitlab:doctor:secrets` báo lỗi giải mã | Khôi phục từ Secrets Manager; nếu không có bản lưu: reset runner token, biến CI/CD, 2FA theo hướng dẫn của GitLab |
| **Một AZ gặp sự cố** | `kubectl get nodes -L topology.kubernetes.io/zone` | Pod không trạng thái tự chạy ở AZ khác; Gitaly phụ thuộc AZ của volume: khôi phục từ snapshot sang AZ khác nếu sự cố kéo dài |

Sau mỗi sự cố mức High trở lên: viết postmortem và bổ sung bảng này.

## 6.7. Lộ trình áp dụng cho hệ thống hiện tại

| Giai đoạn | Việc | Kết quả |
|---|---|---|
| **Ngay** | Tắt Sign-up, đổi mật khẩu và bật 2FA cho `root`, visibility mặc định Private; sao lưu `gitlab-rails-secret` vào Secrets Manager; chạy thử `backup-utility` | Đóng các lỗ hổng cơ bản; có bản sao lưu đầu tiên |
| **1–2 tuần** | Bật CronJob backup; versioning + lifecycle bucket `backups`; HTTPS (ACM) cho cả group ALB; gỡ `minio` khỏi `app_hostnames` | Sao lưu hằng ngày; mã hoá đường truyền |
| **1 tháng** | SSO (SAML/OIDC) + bắt buộc 2FA; Prometheus + cảnh báo; Fluent Bit đẩy log về CloudWatch (12 tháng); quản lý group/project bằng provider `gitlab` | Đáp ứng phần lớn PCI DSS 8, 10 |
| **Trước production** | RDS Multi-AZ + deletion protection + backup 35 ngày + `sslmode=require`; Redis failover; node group riêng cho GitLab; diễn tập khôi phục lần đầu | Chịu được mất 1 node/1 AZ cho DB/Redis; RTO/RPO đã kiểm chứng |
| **Khi tải/tuân thủ đòi hỏi** | Mạng private + WAF; cân nhắc GitLab Premium (approval rules, push rules, audit events, Geo); Gitaly ngoài Kubernetes | Mức enterprise banking |
