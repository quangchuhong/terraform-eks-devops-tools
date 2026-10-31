# 7. Manifest GitLab sinh từ `helm template`

[← Mục lục GitLab](README.md) · [Hướng dẫn chung về `helm template`](../helm-template/README.md)

## 7.1. Render

GitLab được Terraform cài (`helm_release.gitlab`), values gồm file `helm-chart/gitlab-values.yaml` và khối `yamlencode` trong `gitlab-helm.tf` (subnet, endpoint RDS/Redis, bucket, IAM role). Cách đơn giản nhất để có đúng values đó là đọc lại từ release:

```bash
./helm-install/render.sh gitlab
```

Tương đương:

```bash
helm repo add gitlab https://charts.gitlab.io
helm -n gitlab get values gitlab > helm-install/rendered/gitlab.values.yaml
helm template gitlab gitlab/gitlab --version 10.5.4 -n gitlab -f helm-install/rendered/gitlab.values.yaml \
  --kube-version 1.34.0 \
  --api-versions networking.k8s.io/v1/Ingress \
  --api-versions policy/v1/PodDisruptionBudget \
  --api-versions autoscaling/v2/HorizontalPodAutoscaler > helm-install/rendered/gitlab.yaml
```

Bắt buộc có `--kube-version`/`--api-versions`: thiếu thì chart GitLab sinh Ingress kiểu cũ (`serviceName`/`servicePort`), khác với bản chạy trên cụm.

Kiểm tra: Job migrations sinh ra là `gitlab-migrations-cb3b542`, trùng tên Job đã chạy thật trên cụm (`gitlab-migrations-cb3b542-hnjpf`). Tên Job có hash từ values, nên trùng tên nghĩa là values dùng để render khớp với values đã deploy.

## 7.2. Danh sách tài nguyên (61)

| Nhóm | Tài nguyên |
|---|---|
| Workload | Deployment: `gitlab-webservice-default`, `gitlab-sidekiq-all-in-1-v2`, `gitlab-gitlab-shell`, `gitlab-registry`, `gitlab-kas`, `gitlab-toolbox`, `gitlab-gitlab-exporter`; StatefulSet: `gitlab-gitaly`; Job: `gitlab-migrations-<hash>` |
| Service (ClusterIP) | `gitlab-webservice-default` (8080 Puma, **8181 Workhorse**, 8083 metrics), `gitlab-gitaly` (8075 gRPC, 9236 metrics), `gitlab-gitlab-shell` (22 → 2222), `gitlab-registry` (5000), `gitlab-kas` (8150, 8153, 8154, 8151), `gitlab-gitlab-exporter` (9168) |
| Ingress (3) | `gitlab-webservice-default`: `gitlab.gitlabonlinecom.click` → Workhorse 8181; `gitlab-registry`: `registry.gitlabonlinecom.click` → 5000; `gitlab-kas`: `kas.gitlabonlinecom.click` → 8150 (`/`) và 8154 (`/k8s-proxy/`) |
| HPA (5) | webservice 2–10 (CPU trung bình 1 core), sidekiq 1–10 (350m), gitlab-shell 2–10 (100m), kas 2–10 (100m), registry 2–10 (75% CPU) |
| PDB (6) | `maxUnavailable: 1` cho gitaly, gitlab-shell, kas, sidekiq, webservice, registry |
| ServiceAccount (12) | Mỗi thành phần một SA (`gitlab-webservice`, `gitlab-sidekiq`, `gitlab-gitaly`, `gitlab-toolbox`, `gitlab-registry`, `gitlab-migrations`...), **tất cả** có annotation IRSA `...:role/eks-cluster-ver1-gitlab-s3` (`global.serviceAccount.annotations`) |
| ConfigMap (15) | Cấu hình từng thành phần: `gitlab-webservice` (`gitlab.yml.erb`, `database.yml.erb`...), `gitlab-sidekiq`, `gitlab-gitaly` (`config.toml.tpl`), `gitlab-registry`, `gitlab-workhorse-default`, `gitlab-kas`, `gitlab-gitlab-shell`, `gitlab-toolbox`, `gitlab-migrations`... |
| Hook | `gitlab-shared-secrets` (SA, Role, RoleBinding, ConfigMap, Job; `pre-install,pre-upgrade`), `gitlab-gitlab-upgrade-check` (Job), Pod test `gitlab-webservice-test-runner-*` |

Không có trong chart (do Terraform tạo, [1.2](01-kien-truc-va-cau-hinh.md#secret-do-terraform-tạo-namespace-gitlab)): namespace `gitlab`, Secret `gitlab-postgresql-password`, `gitlab-redis-secret`, `gitlab-rails-storage`, `gitlab-registry-storage`; RDS, ElastiCache, S3, IAM role.

## 7.3. Thành phần chính

| Workload | Image (v19.5.3 CE) | Container | Requests (không có limit) | Probe |
|---|---|---|---|---|
| webservice | `gitlab-webservice-ce`, `gitlab-workhorse-ce` | `webservice` (8080, 8083), `gitlab-workhorse` (8181) | 300m / 2.5G; 100m / 100M | `GET /-/readiness`, `/-/liveness`; workhorse `/scripts/healthcheck` |
| sidekiq | `gitlab-sidekiq-ce` | `sidekiq` (3807) | 900m / 2G | `GET /readiness`, `/liveness` cổng 3808 |
| gitaly | `gitaly` | `gitaly` (8075, 9236) | 100m / 200Mi | startup tối đa 60 giây, readiness mỗi 5 giây |
| gitlab-shell | `gitlab-shell:v14.58.0` | `gitlab-shell` (2222) | 0 / 6M | TCP 2222 |
| registry | `gitlab-container-registry:v4.42.0-gitlab` | `registry` (5000, 5001 debug) | 50m / 32Mi | `GET /debug/health` |
| kas | `gitlab-kas` | `kas` (8150, 8151, 8154, 8155) | 100m / 256Mi | `GET /readiness`, `/liveness` cổng 8151 |
| toolbox | `gitlab-toolbox-ce` | `toolbox` | 50m / 350M | — (strategy `Recreate`) |
| gitlab-exporter | `gitlab-exporter:17.0.2` | `gitlab-exporter` (9168) | 75m / 100M | `pgrep` |
| migrations (Job) | `gitlab-toolbox-ce` | `migrations` | 250m / 200Mi | — |

Init container dùng chung ở hầu hết workload:

| Init container | Vai trò |
|---|---|
| `certificates` | Ghép CA vào trust store (`/etc/ssl/certs`) |
| `configure` (`gitlab-base`) | Chép secret từ projected volume `init-*-secrets` vào emptyDir với đúng quyền, render file cấu hình |
| `dependencies` (webservice, sidekiq) | Chờ DB và Redis sẵn sàng, migrations đã chạy |

### Bảo mật pod

| Thuộc tính | Giá trị |
|---|---|
| Pod | `runAsUser 1000`, `fsGroup 1000` (kas: 65532), `seccompProfile: RuntimeDefault` |
| Container | `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop `ALL` |
| Secret | Gắn qua projected volume vào init container, chép sang emptyDir; không nằm trong biến môi trường |

### Lưu trữ

| Tài nguyên | Giá trị |
|---|---|
| Gitaly `volumeClaimTemplates` `repo-data` | gp3, **50Gi** → PVC `repo-data-gitlab-gitaly-0` (mở rộng bằng `kubectl patch pvc`, [2.4](02-sizing.md#24-mở-rộng-ổ-gitaly-khi-gần-đầy)) |
| Thành phần khác | Chỉ emptyDir (không trạng thái); file lớn trên S3 |

### Cấu hình ứng dụng được render (ConfigMap `gitlab-webservice`, `gitlab.yml.erb`)

```yaml
gitlab:
  host: gitlab.gitlabonlinecom.click
  https: false
object_store:
  enabled: true
  proxy_download: true
  connection: <%= YAML.load_file("/etc/gitlab/objectstorage/object_store").to_json() %>
  objects:
    artifacts:
      bucket: gitlab-609320954321-artifacts
    lfs:
      bucket: gitlab-609320954321-lfs
    # ... uploads, packages, external_diffs, terraform_state, ci_secure_files, dependency_proxy ...
```

`connection` đọc từ Secret `gitlab-rails-storage` (Terraform tạo: `provider: AWS`, `use_iam_profile: true`), nên không có access key trong cấu hình.

### Ingress

Cả 3 Ingress dùng annotation `kubernetes.io/ingress.class: alb` (không dùng `ingressClassName`) và cùng bộ annotation ALB lấy từ `global.ingress.annotations`:

| Annotation | Giá trị |
|---|---|
| `group.name` | `alb-apps` |
| `listen-ports` | `[{"HTTP":80}]` |
| `load-balancer-attributes` | `idle_timeout.timeout_seconds=600` |
| `target-group-attributes` | sticky cookie 3600 giây |
| `success-codes` | `200-399` |
| `tags` | `Environment=prod,Application=gitlab-alb` |
| `subnets` | 3 subnet public (Terraform) |

Người dùng vào GitLab qua **Workhorse (8181)**, không vào thẳng Puma (8080).

### Hook

| Hook | Khi nào | Làm gì |
|---|---|---|
| Job `gitlab-shared-secrets-<hash>` | `pre-install`, `pre-upgrade` | Sinh các secret nội bộ nếu chưa có: `gitlab-rails-secret`, `gitlab-gitaly-secret`, `gitlab-gitlab-shell-secret`, `gitlab-registry-secret`, `gitlab-gitlab-workhorse-secret`, `gitlab-gitlab-kas-secret`, `gitlab-gitlab-initial-root-password`... Đã có thì giữ nguyên |
| Job `gitlab-gitlab-upgrade-check` | `pre-upgrade` | Chặn nâng cấp sai upgrade path |
| Job `gitlab-migrations-<hash>` | Mỗi lần values/phiên bản đổi | Chạy migration DB trên RDS |

## 7.4. Nhận xét từ manifest

| # | Phát hiện | Mức | Đề xuất |
|---|---|---|---|
| 1 | Hầu hết container **không có memory limit** (mặc định chart) | Trung bình | Chấp nhận với lab; production đặt limit cho webservice/sidekiq (ví dụ 4–6Gi) để một pod không ăn hết bộ nhớ node ([2.3](02-sizing.md#23-ví-dụ-values-cho-từng-mức)) |
| 2 | Requests webservice 2.5G × 2 + sidekiq 2G × (1–3) trên 3 node `t3.xlarge` dùng chung | Trung bình | Theo dõi; khi tải tăng, đưa GitLab sang node group riêng |
| 3 | `https: false` trong `gitlab.yml` | Đã biết | Đổi `global.hosts.https: true` cùng lúc bật HTTPS trên ALB |
| 4 | IRSA gắn cho **mọi** service account (kể cả gitlab-shell, kas, exporter không cần S3) | Thấp | Chấp nhận (cấu hình chung của chart); có thể gắn riêng cho từng thành phần qua `gitlab.<thành phần>.serviceAccount.annotations` |
| 5 | Service `gitlab-gitlab-shell` cổng 22 chỉ ClusterIP | Thông tin | SSH chưa ra ngoài ([3.3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening)) |
| 6 | PDB `maxUnavailable: 1` cho Gitaly 1 replica | Thông tin | Drain node vẫn được, Gitaly gián đoạn trong lúc chuyển node |
| 7 | Non-root, seccomp, drop capabilities cho mọi container | Tốt | Giữ nguyên |
