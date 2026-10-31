# 1. Kiến trúc GitLab và các tuỳ chọn cấu hình

[← Mục lục GitLab](README.md)

## 1.1. Tổng quan

GitLab cài bằng chart cloud-native `gitlab/gitlab` 10.5.4 (GitLab 19.5.3 CE). Từ chart 10.x (GitLab 19), chart **không còn đi kèm PostgreSQL, Redis và MinIO**. Phần dữ liệu có trạng thái được đưa ra dịch vụ AWS, cụm EKS chỉ chạy các thành phần ứng dụng và Gitaly.

```
                    Internet (HTTP :80)
                           │
              ┌────────────▼─────────────┐
              │ ALB group alb-apps       │  gitlab.  registry.  kas.  (+ jenkins., nexus., sonarqube. ...)
              └────────────┬─────────────┘
                           │ target-type ip
┌──────────────────────────┼──────────────── namespace gitlab (node thường eks_nodes) ─────────────────┐
│                          ▼                                                                           │
│  webservice (Puma + Workhorse) ×2 ──┐       registry ×2 ──────────────┐   kas ×2 (agent Kubernetes)  │
│        │            │               │                                 │                              │
│        │ gRPC       │ Redis/PG      │ job nền                         │ S3                           │
│        ▼            │               ▼                                 │                              │
│  gitaly-0 (StatefulSet)   sidekiq ×1–N (HPA)                          │   gitlab-shell ×2 (SSH, chưa │
│   PVC EBS gp3 (repo Git)    │                                         │   mở ra ngoài)               │
│                             │                                         │                              │
│  toolbox (backup, rails console)   gitlab-exporter   migrations (Job mỗi lần cài/nâng cấp)          │
└─────────────────────────────┼─────────────────────────────────────────┼──────────────────────────────┘
                              │                                         │
       ┌──────────────────────┼─────────────────────┐                   │
       ▼                      ▼                     ▼                   ▼
 RDS PostgreSQL 17     ElastiCache Redis 7     S3 gitlab-609320954321-* (13 bucket)
 gitlabhq_production   TLS (rediss) + AUTH     artifacts, lfs, uploads, packages, mr-diffs, registry,
 db.t4g.medium, gp3    cache.t4g.small         backups, tmp, terraform-state, ... (IRSA, SSE-S3)
 mã hoá, 1 AZ          mã hoá, 1 node
```

| Thành phần | Kiểu | Vai trò |
|---|---|---|
| **webservice** | Deployment (HPA, mặc định 2 pod) | Giao diện web, API, Git qua HTTP. Gồm container `webservice` (Puma, Rails) và `gitlab-workhorse` (proxy: upload/download file lớn, Git HTTP) |
| **sidekiq** | Deployment (HPA, đang 3 pod) | Xử lý job nền: gửi mail, pipeline, mirror, xoá dữ liệu, cập nhật thống kê |
| **gitaly** | StatefulSet 1 pod | Lưu và phục vụ repo Git (mọi thao tác Git đi qua gRPC tới Gitaly). Dữ liệu trên PVC EBS gp3 |
| **gitlab-shell** | Deployment (2 pod) | Git qua SSH. **Chưa mở ra ngoài** vì ALB chỉ hỗ trợ HTTP/HTTPS |
| **registry** | Deployment (2 pod) | GitLab Container Registry, lưu layer trên S3 (`registry.gitlabonlinecom.click`) |
| **kas** | Deployment (2 pod) | GitLab Agent for Kubernetes server (`kas.gitlabonlinecom.click`) |
| **toolbox** | Deployment (1 pod) | Công cụ quản trị: `backup-utility`, `gitlab-rails console`, rake task |
| **gitlab-exporter** | Deployment | Xuất metric cho Prometheus (Prometheus chưa cài) |
| **migrations** | Job | Chạy migration DB mỗi lần cài hoặc nâng cấp |
| RDS PostgreSQL 17 | AWS | Toàn bộ metadata: user, group, project, MR, issue, pipeline, cấu hình |
| ElastiCache Redis 7 | AWS | Cache, session, hàng đợi Sidekiq |
| S3 (13 bucket) | AWS | File lớn và backup (danh sách ở [1.2](#object-storage-s3)) |

Tắt trong values: NGINX Ingress (dùng ALB), cert-manager, GitLab Pages, Mattermost, Prometheus đi kèm, GitLab Runner đi kèm (Runner cài riêng, xem [CI agents](../ci-agents/README.md)), Gateway API/Envoy (mặc định mới của chart 10.x).

### Luồng một request

1. Người dùng mở `http://gitlab.gitlabonlinecom.click` → Route 53 (alias) → ALB `alb-apps` → pod `webservice` (target-type `ip`, sticky cookie 1 giờ).
2. Workhorse nhận request: file tĩnh/upload xử lý trực tiếp; còn lại chuyển cho Puma (Rails).
3. Rails đọc/ghi metadata trên **RDS**, cache và session trên **Redis**, thao tác repo qua **Gitaly** (gRPC), file trên **S3** (`proxy_download: true`: tải file qua GitLab, không lộ URL S3 ra ngoài).
4. Việc chạy lâu (mirror, pipeline, email) được đưa vào hàng đợi Redis cho **Sidekiq**.

### Git clone/push (Jenkins, lập trình viên)

- **HTTP** (đang dùng): `http://gitlab.gitlabonlinecom.click/<group>/<project>.git`, xác thực bằng Personal/Project/Group Access Token (không dùng mật khẩu).
- **SSH**: `gitlab-shell` đang chạy nhưng chưa có đường vào (ALB không chuyển TCP 22). Muốn bật cần NLB riêng cho cổng 22 (xem [3.3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening)).

## 1.2. Các nhóm cấu hình và ý nghĩa

Cấu hình chia làm hai lớp:

- `helm-chart/gitlab-values.yaml`: phần không phụ thuộc account (bật/tắt thành phần, Ingress, tên Secret).
- `gitlab-helm.tf` (`yamlencode` trong `helm_release.gitlab`): phần phụ thuộc hạ tầng (subnet ALB, endpoint RDS/Redis, tên bucket, ARN IAM role, domain).

### Chung (`global`)

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `edition` | `ce` | Community Edition (miễn phí). Đổi `ee` để dùng EE (cần license cho tính năng trả phí) |
| `hosts.domain` | `gitlabonlinecom.click` (Terraform `var.domain`) | Sinh host `gitlab.`, `registry.`, `kas.` |
| `hosts.https` | `false` | Chỉ HTTP. Phải đổi `true` khi bật HTTPS để GitLab sinh URL `https://` |
| `gatewayApi.enabled`, `installEnvoy` | `false` | Chart 10.x mặc định dùng Gateway API + Envoy; tắt để dùng Ingress của ALB |

### Ingress (ALB)

| Annotation | Giá trị | Ý nghĩa |
|---|---|---|
| `group.name` | `alb-apps` | Dùng chung một ALB với các tool khác. Mọi Ingress trong group phải có annotation giống nhau (subnets, listen-ports) |
| `scheme` | `internet-facing` | ALB public |
| `listen-ports` | `[{"HTTP":80}]` | Chỉ HTTP |
| `target-type` | `ip` | ALB gửi thẳng tới IP pod |
| `load-balancer-attributes` | `idle_timeout.timeout_seconds=600` | Cho phép clone/push repo lớn, upload lâu |
| `target-group-attributes` | sticky 3600 giây | Giữ phiên trên cùng pod |
| `success-codes` | `200-399` | Health check chấp nhận redirect (trang chủ chuyển về `/users/sign_in`) |
| `subnets` | `var.subnet_ids` (Terraform) | 3 subnet public |

### PostgreSQL (`global.psql`)

| Khoá | Giá trị |
|---|---|
| `host` | Endpoint RDS `eks-cluster-ver1-gitlab.c7wy4wkquclc.ap-southeast-1.rds.amazonaws.com` (Terraform) |
| `database` / `username` | `gitlabhq_production` / `gitlab` |
| `password.secret` | Secret `gitlab-postgresql-password` (key `postgresql-password`), mật khẩu 32 ký tự do `random_password` sinh |

RDS (`gitlab-backend.tf`): PostgreSQL 17, `db.t4g.medium`, gp3 50 GB tự tăng tới 200 GB, mã hoá, không public, 1 AZ, backup tự động 7 ngày, tự nâng minor version. Cùng RDS này còn chứa database `sonarqube` (tạo bằng Job trong `sonarqube-backend.tf`).

### Redis (`global.redis`)

| Khoá | Giá trị |
|---|---|
| `host` | Primary endpoint ElastiCache (Terraform) |
| `scheme` | `rediss` (TLS) |
| `auth.secret` | Secret `gitlab-redis-secret` (key `redis-password`) |

ElastiCache: Redis 7.1, `cache.t4g.small`, 1 node, mã hoá khi lưu và khi truyền, có AUTH token, không failover tự động.

### Object storage (S3)

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `appConfig.object_store.enabled` | `true` | Dùng chung một kết nối cho mọi loại file |
| `object_store.connection` | Secret `gitlab-rails-storage`: `provider: AWS`, `use_iam_profile: true`, `region` | Không access key: dùng IAM role của service account |
| `object_store.proxy_download` | `true` | Tải file qua GitLab (không redirect ra S3) |
| `externalDiffs`, `terraformState`, `ciSecureFiles`, `dependencyProxy` | `enabled: true` | Lưu diff MR, Terraform state, secure file, cache image proxy trên S3 |
| `registry.storage` | Secret `gitlab-registry-storage` (driver S3, bucket `-registry`) | Layer image của Container Registry |
| `backups` | bucket `-backups`, `tmpBucket` `-tmp`, backend `s3` | Đích của `backup-utility` |
| `serviceAccount.annotations` | `eks.amazonaws.com/role-arn` = role `eks-cluster-ver1-gitlab-s3` | IRSA cho **mọi** service account của chart trong namespace `gitlab` |

13 bucket `gitlab-609320954321-<loại>`: `artifacts`, `lfs`, `uploads`, `packages`, `mr-diffs`, `terraform-state`, `ci-secure-files`, `dependency-proxy`, `agent-plan-content`, `ci-catalog-bundles`, `registry`, `backups`, `tmp`. Tất cả chặn public, `BucketOwnerEnforced`, mã hoá SSE-S3 (AES256). Role IAM chỉ có quyền trên đúng 13 bucket này.

### Gitaly

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `gitlab.gitaly.persistence.storageClass` | `gp3` | EBS gp3 mã hoá, `allowVolumeExpansion`, `WaitForFirstConsumer` |
| Kích thước PVC | mặc định chart (50Gi) | Chứa toàn bộ repo Git |

Volume EBS gắn với một AZ, nên node group `eks_nodes` giữ tối thiểu 1 node mỗi AZ (`min_size = 3`) để pod `gitlab-gitaly-0` luôn có chỗ chạy lại.

### Secret do Terraform tạo (namespace `gitlab`)

| Secret | Nội dung |
|---|---|
| `gitlab-postgresql-password` | Mật khẩu DB `gitlab` |
| `gitlab-redis-secret` | AUTH token Redis |
| `gitlab-rails-storage` | Kết nối object storage (không chứa key) |
| `gitlab-registry-storage` | Cấu hình driver S3 của registry |

Secret do chart tự sinh, cần sao lưu: `gitlab-gitlab-initial-root-password` (mật khẩu `root` ban đầu), **`gitlab-rails-secret`** (khoá mã hoá dữ liệu nhạy cảm trong DB: token CI, biến CI/CD, 2FA; mất là không giải mã được), `gitlab-gitaly-secret`, `gitlab-gitlab-shell-secret`, `gitlab-registry-secret`, `gitlab-gitlab-workhorse-secret`, `gitlab-gitlab-kas-secret`...

### DNS

`dns.tf` tạo hosted zone `gitlabonlinecom.click` (domain đăng ký bằng Route 53 cùng account, Terraform trỏ NS về zone). Khi `enable_dns_records = true`, `gitlab-helm.tf` tạo bản ghi alias A cho mọi tên trong `var.app_hostnames` trỏ về ALB, lấy từ `status` của Ingress `gitlab-webservice-default` (không tìm ALB theo tag, tránh nhầm với ALB cũ).

## 1.3. Tổ chức group và project hiện tại

| Đường dẫn | Mục đích |
|---|---|
| `devops/ci-cd/shopping-cart` | Mã nguồn app mẫu (mirror từ GitHub `ci-cd-maven-java-ver1`), Jenkins Multibranch build |
| `devops/ci-cd/gitops-shopping-cart` | Repo GitOps cho Argo CD (CD đang tạm dừng) |
| `devops/ci-cd/jenkins-shared-library` | Thư viện `ci-lib` (dự kiến, [Jenkins 7](../jenkins/07-shared-library.md)) |
| `dev/...` | Group của team phát triển |

Token cho Jenkins: Group Access Token tạo ở group **`devops`** (token tạo ở group `dev` không đọc được project trong `devops`), lưu trong Secret `jenkins/gitlab-ci`, Jenkins dùng qua credential `gitlab-token-dev-group`.
