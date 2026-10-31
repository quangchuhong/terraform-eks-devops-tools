# Manifest GitLab Runner sinh từ `helm template`

[← CI agents](README.md) · [Hướng dẫn chung về `helm template`](../helm-template/README.md)

## 1. Render

```bash
./helm-install/render.sh gitlab-runner
```

Tương đương:

```bash
helm repo add gitlab https://charts.gitlab.io
helm template gitlab-runner gitlab/gitlab-runner --version 0.94.0 -n gitlab-runner \
  -f helm-install/gitlab-runner/values.yaml --kube-version 1.34.0 > helm-install/rendered/gitlab-runner.yaml
```

## 2. Danh sách tài nguyên (5)

| Kind | Tên | Vai trò | Sinh từ values |
|---|---|---|---|
| ServiceAccount | `gitlab-runner` | Danh tính của runner manager (tạo pod job) | `serviceAccount.create/name` |
| ConfigMap | `gitlab-runner` | `entrypoint`, `register-the-runner`, `check-live`, `pre-entrypoint-script`, `config.toml`, `config.template.toml` | `concurrent`, `checkInterval`, `runners.config` |
| Role | `gitlab-runner` | Quyền trong namespace `gitlab-runner` | `rbac.rules` |
| RoleBinding | `gitlab-runner` | Gán Role cho ServiceAccount | `rbac.create` |
| Deployment | `gitlab-runner` | Runner manager (1 pod) | `image`, `resources`, `terminationGracePeriodSeconds`... |

Secret `gitlab-runner-token` **không** do chart tạo: tạo trước bằng `kubectl` ([CI agents, bước 5](README.md#bước-5-gitlab-runner)), chart chỉ tham chiếu qua `runners.secret`.

## 3. Deployment `gitlab-runner`

```
Deployment gitlab-runner (replicas mặc định 1, serviceAccountName gitlab-runner, terminationGracePeriodSeconds 3600)
  securityContext pod: runAsUser 100, fsGroup 65533
  containers:
    gitlab-runner   registry.gitlab.com/gitlab-org/gitlab-runner:alpine-v19.5.0   cổng 9252 (metrics, đang tắt)
      command: dumb-init -- /bin/bash /configmaps/entrypoint
      env: CI_SERVER_URL=http://gitlab.gitlabonlinecom.click/, RUNNER_EXECUTOR=kubernetes, REGISTER_LOCKED=true
      mounts: /secrets (projected Secret gitlab-runner-token)
              /home/gitlab-runner/.gitlab-runner (emptyDir: config.toml sinh lúc chạy)
              /configmaps (ConfigMap gitlab-runner)
```

| Thuộc tính | Giá trị render | Từ values |
|---|---|---|
| Image | `alpine-v19.5.0` | `image.tag` |
| Resources | requests `50m` / `128Mi`, limits `500m` / `256Mi` | `resources` |
| liveness | `bash /configmaps/check-live 3` mỗi 60 giây (kiểm tra runner còn kết nối GitLab) | Chart |
| readiness | `pgrep gitlab.*runner` | Chart |
| securityContext container | `runAsNonRoot`, không privileged, drop `ALL`, không privilege escalation | `securityContext` |
| `terminationGracePeriodSeconds` | 3600 | Cho job đang chạy hoàn tất khi pod bị thay |
| Projected Secret | `runner-token`, `runner-registration-token` từ Secret `gitlab-runner-token` | `runners.secret` |

Khi pod khởi động, `entrypoint` ghép `config.template.toml` (cấu hình executor Kubernetes) với token trong `/secrets` thành `config.toml` thật trong emptyDir, rồi chạy `gitlab-runner run`. Token không bao giờ nằm trong ConfigMap.

## 4. Cấu hình executor (`config.template.toml` trong ConfigMap)

```toml
[[runners]]
  request_concurrency = 4
  [runners.kubernetes]
    namespace = "gitlab-runner"
    image = "alpine:3.22"
    privileged = false
    allow_privilege_escalation = false
    poll_timeout = 600
    cpu_request = "500m"
    memory_request = "1Gi"
    cpu_limit = "2"
    memory_limit = "4Gi"
    ephemeral_storage_request = "2Gi"
    ephemeral_storage_limit = "20Gi"
    helper_cpu_request = "50m"
    helper_memory_request = "64Mi"
    helper_memory_limit = "256Mi"
    service_cpu_request = "100m"
    service_memory_request = "256Mi"
    service_memory_limit = "1Gi"
    [runners.kubernetes.node_selector]
      workload = "ci-agents"
    [runners.kubernetes.node_tolerations]
      "workload=ci-agents" = "NoSchedule"
    [runners.kubernetes.pod_labels]
      "app.kubernetes.io/part-of" = "gitlab-runner-job"
```

`config.toml` (phần chung): `concurrent = 10`, `check_interval = 3`, `log_level = "info"`. `namespace = "{{ .Release.Namespace }}"` trong values đã được Helm thay thành `gitlab-runner`.

Pod job do runner tạo lúc chạy, **không** xuất hiện trong `helm template`: cấu hình của chúng chính là khối `[runners.kubernetes]` ở trên (container `build`, `helper`, các `services`).

## 5. Role `gitlab-runner`

| Resources | Verbs | Dùng để |
|---|---|---|
| `pods` | create, delete, get, list, watch | Tạo và theo dõi pod job |
| `pods/attach`, `pods/exec` | create, delete, get, patch | Chạy script trong container job |
| `pods/log` | get, list | Lấy log job |
| `secrets`, `configmaps` | create, delete, get, update | Credential registry, biến CI, script tạm cho từng job |
| `services` | create, get | Service cho `services:` của job |
| `serviceaccounts` | get | Kiểm tra service account của job |
| `events` | list, watch | In cảnh báo khi pod job lỗi (ví dụ thiếu tài nguyên) |

Tất cả chỉ trong namespace `gitlab-runner` (Role, không phải ClusterRole).

## 6. Nhận xét từ manifest

| # | Phát hiện | Mức | Đề xuất |
|---|---|---|---|
| 1 | Pod job không privileged, chạy trên node CI | Tốt | Giữ nguyên; build image bằng Kaniko/BuildKit |
| 2 | Role chỉ trong namespace, quyền tối thiểu | Tốt | |
| 3 | Pod job dùng service account `default` của namespace | Thông tin | Nếu job cần quyền AWS: tạo service account riêng có IRSA và đặt `service_account` trong `[runners.kubernetes]`, không gắn IRSA cho `default` |
| 4 | Metrics (9252) tắt | Thấp | Bật `metrics.enabled` khi có Prometheus |
| 5 | `RUNNER_TAG_LIST` rỗng trong env | Thông tin | Tag được đặt khi tạo runner trên GitLab (`eks,k8s`), không cần trong values |
