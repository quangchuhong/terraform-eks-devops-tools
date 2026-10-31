# 5. Hướng dẫn cấu hình đã triển khai

[← Mục lục GitLab](README.md)

GitLab được cài **bằng Terraform** (khác với Jenkins, Nexus, SonarQube cài bằng helm CLI), vì GitLab gắn chặt với hạ tầng AWS: RDS, ElastiCache, 13 bucket S3, IAM role, Route 53.

## 5.1. Điều kiện trước

| Điều kiện | Kiểm tra |
|---|---|
| AWS CLI đăng nhập đúng account `609320954321`, region `ap-southeast-1` | `aws sts get-caller-identity` |
| Terraform ≥ 1.11 (state lock bằng file trên S3), `kubectl`, `helm` | `terraform version` |
| VPC và 3 subnet **public** (ALB internet-facing, node EKS) | `variables.tf`: `vpc_id`, `subnet_ids` |
| Domain `gitlabonlinecom.click` đăng ký bằng Route 53 cùng account | `manage_domain_nameservers = true` |
| Bucket state `tfstate-609320954321-ap-southeast-1` | Tạo bằng thư mục `bootstrap/` (một lần) |

## 5.2. Các file cấu hình

| File | Nội dung |
|---|---|
| `gitlab-backend.tf` | Security group dữ liệu, RDS PostgreSQL 17, ElastiCache Redis 7 (TLS + AUTH), 13 bucket S3, IAM role IRSA `eks-cluster-ver1-gitlab-s3`, namespace `gitlab`, 4 Secret |
| `gitlab-helm.tf` | `helm_release.gitlab` (chart 10.5.4, timeout 15 phút), đọc DNS của ALB từ Ingress, bản ghi Route 53 cho `app_hostnames` |
| `helm-chart/gitlab-values.yaml` | Values của chart (Ingress ALB, psql, redis, object storage, tắt thành phần thừa) |
| `variables.tf` | `gitlab_chart_version`, `gitlab_db_*`, `gitlab_redis_node_type`, `gitlab_s3_force_destroy`, `domain`, `app_hostnames`, `enable_dns_records` |
| `dns.tf` | Hosted zone, trỏ NS của domain |
| `terraform.tfvars` (không commit) | Giá trị riêng: `enable_dns_records = true`, `cluster_admin_arns`... |

## 5.3. Cài đặt (3 lượt apply)

Phải tách lượt vì Kubernetes/Helm provider cần cụm EKS có trước, và bản ghi DNS cần ALB có trước.

**Lượt 0. State backend (một lần):**

```bash
cd bootstrap && terraform init && terraform apply && cd ..
terraform init
terraform validate
```

**Lượt 1. Cụm EKS:**

```bash
terraform plan -target=module.eks -out=eks.tfplan
terraform apply eks.tfplan
aws eks update-kubeconfig --name eks-cluster-ver1 --region ap-southeast-1
kubectl get nodes
```

Mất khoảng 12–20 phút.

**Lượt 2. Add-on và GitLab:** Load Balancer Controller, Cluster Autoscaler, metrics-server, EBS CSI, RDS, ElastiCache, S3, IAM và GitLab.

```bash
terraform plan -out=all.tfplan
terraform apply all.tfplan
kubectl get pods -n gitlab -w
kubectl get ingress -n gitlab
```

`helm_release.gitlab` mất khoảng 9 phút (Job migrations chạy trên RDS). Chờ cột `ADDRESS` của Ingress có DNS của ALB (`k8s-albapps-...elb.amazonaws.com`).

Lúc mới khởi động, có thể thấy `sidekiq` 0/1 và restart 1 lần, `webservice` 1/2, `kas` restart vài lần. Đây là bình thường (Rails nạp chậm, Puma warm-up); chờ 5–10 phút.

**Lượt 3. Bản ghi DNS:**

```bash
echo 'enable_dns_records = true' >> terraform.tfvars
terraform plan -out=dns.tfplan
terraform apply dns.tfplan
terraform output alb_dns_name
```

Đặt `enable_dns_records` trong `terraform.tfvars`, **không** dùng `-var` một lần: lần apply sau thiếu cờ này sẽ xoá hết bản ghi.

## 5.4. Kiểm tra sau khi cài

```bash
helm list -n gitlab
kubectl get pods -n gitlab
curl -sI http://gitlab.gitlabonlinecom.click/users/sign_in | head -1
dig +short gitlab.gitlabonlinecom.click @8.8.8.8
```

Kết quả thực tế khi cài:

```
NAME    NAMESPACE  REVISION  STATUS    CHART          APP VERSION
gitlab  gitlab     1         deployed  gitlab-10.5.4  v19.5.3

gitlab-gitaly-0                               1/1  Running
gitlab-gitlab-exporter-...                    1/1  Running
gitlab-gitlab-shell-... (×2)                  1/1  Running
gitlab-kas-... (×2)                           1/1  Running
gitlab-migrations-...                         0/1  Completed
gitlab-registry-... (×2)                      1/1  Running
gitlab-sidekiq-all-in-1-v2-... (×3)           1/1  Running
gitlab-toolbox-...                            1/1  Running
gitlab-webservice-default-... (×2)            2/2  Running

HTTP/1.1 200 OK
```

Chưa có DNS thì kiểm tra qua ALB bằng header `Host`:

```bash
curl -sI -H "Host: gitlab.gitlabonlinecom.click" http://$(terraform output -raw alb_dns_name)/users/sign_in | head -1
```

## 5.5. Đăng nhập lần đầu và cấu hình ban đầu

Mật khẩu `root` ban đầu (chỉ hiện trên terminal của bạn, không dán vào chat hay tài liệu):

```bash
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo
```

Mở http://gitlab.gitlabonlinecom.click, đăng nhập `root`, rồi làm ngay:

| # | Việc | Đường dẫn trên giao diện |
|---|---|---|
| 1 | Đổi mật khẩu `root`, bật 2FA | Avatar → Edit profile → Password / Account → Two-factor authentication |
| 2 | Tắt đăng ký tự do | Admin → Settings → General → Sign-up restrictions → bỏ *Sign-up enabled* |
| 3 | Visibility mặc định `Private` | Admin → Settings → General → Visibility and access controls |
| 4 | Tạo tài khoản admin có tên riêng, hạn chế dùng `root` | Admin → Users → New user |
| 5 | (Khuyến nghị) Bắt buộc 2FA cho mọi người | Admin → Settings → General → Sign-in restrictions |
| 6 | Đặt thời hạn tối đa cho access token | Admin → Settings → General → Account and limit |

## 5.6. Group, project và token cho CI

**Cấu trúc đang dùng:**

```
devops/                       (group nền tảng)
└── ci-cd/                    (subgroup)
    ├── shopping-cart         (app mẫu, mirror từ GitHub)
    ├── gitops-shopping-cart  (repo GitOps cho Argo CD)
    └── jenkins-shared-library (dự kiến, ci-lib)
dev/                          (group team phát triển)
```

**Tạo project rỗng để mirror từ GitHub:** khi tạo project, **bỏ chọn** *Initialize repository with a README*. Nếu đã lỡ tạo README, lần push đầu bị từ chối (`fetch first`), xử lý ở [5.10](#510-sự-cố-đã-gặp).

**Đẩy repo app từ GitHub lên GitLab** (repo app có hai remote):

```bash
git remote add gitlab http://gitlab.gitlabonlinecom.click/devops/ci-cd/shopping-cart.git
git remote -v
git push gitlab main
git push gitlab develop
```

Git hỏi mật khẩu: nhập **access token** (user bất kỳ hoặc `oauth2`), không nhập mật khẩu GitLab.

**Token cho Jenkins** (Group Access Token):

1. Group **`devops`** → Settings → Access tokens → Add new token. Tạo ở `devops`, không tạo ở `dev`, vì token chỉ thấy project trong group đã tạo nó.
2. Role: `Reporter`; scopes: `read_api`, `read_repository`; đặt ngày hết hạn.
3. Lưu vào Secret của Jenkins (token không xuất hiện trên màn hình hay lịch sử shell):

```bash
read -r -s -p "GitLab group token: " GL_TOKEN; echo
kubectl -n jenkins create secret generic gitlab-ci --from-literal=username=oauth2 --from-literal=token="$GL_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
unset GL_TOKEN
kubectl -n jenkins delete pod jenkins-0
```

Jenkins đọc qua JCasC thành credential `gitlab-token-dev-group`. Kiểm tra token đọc được repo (không in token):

```bash
kubectl -n jenkins get secret gitlab-ci -o jsonpath='{.data.token}' | base64 -d | xargs -I{} git ls-remote http://oauth2:{}@gitlab.gitlabonlinecom.click/devops/ci-cd/shopping-cart.git | head -3
```

**Token cho GitLab Runner:** xem [CI agents, bước 5](../ci-agents/README.md#bước-5-gitlab-runner).

## 5.7. Nâng cấp

`gitlab_chart_version` là **phiên bản chart**, không phải phiên bản GitLab. Tra tương ứng:

```bash
helm repo add gitlab https://charts.gitlab.io
helm repo update gitlab
helm search repo gitlab/gitlab --versions | head -20
```

| Loại nâng cấp | Cách làm |
|---|---|
| **Bản vá** cùng minor (19.5.3 → 19.5.x) | Đổi `gitlab_chart_version` trong `variables.tf` hoặc `terraform.tfvars`, `terraform plan` (chỉ `helm_release.gitlab` update in-place), `terraform apply`. Migrations chạy tự động |
| **Minor/major** (19.5 → 19.8, 19 → 20) | Theo **upgrade path** (các bản dừng bắt buộc), tra bằng GitLab Upgrade Path tool. Mỗi bản dừng là một lần đổi version + apply, chờ *background migrations* xong (Admin → Monitoring → Background migrations) rồi mới đi tiếp. Sao lưu trước |
| **Major của chart** (9.x → 10.x) | Đọc kỹ release notes của chart: có thể bỏ thành phần đi kèm, đổi key values, yêu cầu PostgreSQL/Redis mới hơn |

Quy trình chi tiết, kiểm tra trước và sau: [6.3](06-van-hanh-va-tu-dong-hoa.md#63-nâng-cấp-theo-upgrade-path).

**Đã làm:** chuyển từ chart 9.11.5 (GitLab 18.11.4, dùng PostgreSQL/Redis/MinIO trong cụm) sang chart 10.5.4 (GitLab 19.5.3, dữ liệu ra RDS/ElastiCache/S3) bằng cách **cài lại sạch** (khi đó chưa có dữ liệu cần giữ), không đi theo upgrade path. Với hệ thống đã có dữ liệu, phải nâng tại chỗ qua các bản dừng và di chuyển dữ liệu (backup/restore) sang dịch vụ ngoài.

## 5.8. Sao lưu và khôi phục (tóm tắt)

| Dữ liệu | Cách sao lưu |
|---|---|
| Repo, DB, upload (bản sao lưu ứng dụng) | `backup-utility` trong pod toolbox → bucket `gitlab-609320954321-backups` |
| Database | RDS automated backup 7 ngày (+ snapshot thủ công trước nâng cấp) |
| Repo Git | Snapshot EBS của PVC Gitaly |
| File trên S3 | Đã nằm trên S3 (cân nhắc versioning/replication) |
| **Secret của chart** | `gitlab-rails-secret` và các secret khác: xuất ra nơi an toàn (Secrets Manager), **bắt buộc** để khôi phục |

Chạy backup thủ công:

```bash
kubectl -n gitlab exec deploy/gitlab-toolbox -- backup-utility --s3tool awscli
aws s3 ls s3://gitlab-609320954321-backups/
```

Quy trình đầy đủ (lịch tự động, khôi phục, kiểm tra): [6.5](06-van-hanh-va-tu-dong-hoa.md#65-sao-lưu-và-khôi-phục).

## 5.9. Gỡ cài đặt

```bash
terraform destroy -target=helm_release.gitlab
```

- PVC Gitaly còn lại sau khi gỡ release. Xoá PVC (`kubectl -n gitlab delete pvc repo-data-gitlab-gitaly-0`) sẽ xoá luôn volume EBS chứa repo: snapshot trước.
- RDS: `gitlab_db_deletion_protection = false` thì `destroy` xoá DB **không giữ snapshot cuối**. Môi trường thật phải đặt `true`.
- S3: `gitlab_s3_force_destroy = false` (mặc định) thì `destroy` dừng lại nếu bucket còn dữ liệu, tránh xoá nhầm.

## 5.10. Sự cố đã gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Error: Search returned 2 results` ở `data.aws_lb.selected` | Tìm ALB theo tag, account còn ALB cũ trùng tag | Đổi sang đọc DNS của ALB từ `status` của Ingress `gitlab-webservice-default` (`local.alb_dns_name`) |
| `EntityAlreadyExists` khi tạo IAM role/policy (`eks-gitlab-runner-role`, `gitlab-runner-s3-cache`, `AWSLoadBalancerControllerIAMPolicy`) | Tài nguyên đã có trong account từ lần cài trước nhưng không có trong state | `terraform import` tài nguyên đó, hoặc xoá bản cũ nếu không dùng |
| Chart 9.x có pod `gitlab-postgresql-0`, `gitlab-minio`, nâng lên 10.x không còn | Chart 10.x (GitLab 19) bỏ PostgreSQL/Redis/MinIO đi kèm | Tạo RDS, ElastiCache, S3 (`gitlab-backend.tf`) và trỏ `global.psql`, `global.redis`, `object_store` |
| Chart 10.x tạo Gateway/Envoy thay vì Ingress | Mặc định mới của chart | `global.gatewayApi.enabled: false`, `installEnvoy: false`, giữ `global.ingress` |
| `sidekiq` 0/1, `webservice` 1/2, `kas` restart ngay sau khi cài | Rails/Puma khởi động chậm, chờ DB migrations | Chờ 5–10 phút; nếu vẫn lỗi xem `kubectl logs deploy/gitlab-sidekiq-all-in-1-v2` |
| Không mở được `gitlab.gitlabonlinecom.click` dù Ingress có ADDRESS | Chưa tạo bản ghi DNS (lượt 3), hoặc NS của domain chưa trỏ về zone mới | `enable_dns_records = true`; kiểm tra `dig NS gitlabonlinecom.click` |
| `remote: HTTP Basic: Access denied` khi Jenkins/git clone | Token tạo ở group `dev` không thấy project trong `devops`; hoặc token hết hạn, sai scope | Tạo Group Access Token ở `devops` với `read_repository` (+ `read_api`) |
| `! [rejected] main -> main (fetch first)` khi push lần đầu | Project được tạo kèm README | `git pull gitlab main --allow-unrelated-histories -X ours`, kiểm tra, rồi push; lần sau tạo project rỗng |
| GitHub chặn push repo hạ tầng (push protection) | Có secret (key, token) trong commit | Gỡ secret khỏi commit (viết lại lịch sử nhánh chưa chia sẻ), **xoay vòng secret đã lộ**; không bấm "allow secret" |
