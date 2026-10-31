# 8. Manifest Trivy server sinh từ `helm template`

[← Mục lục Trivy](README.md) · [Hướng dẫn chung về `helm template`](../helm-template/README.md)

## 8.1. Render

```bash
./helm-install/render.sh trivy
```

Tương đương:

```bash
helm template trivy ./helm-install/trivy-scanner/trivy -n trivy --kube-version 1.34.0 > helm-install/rendered/trivy.yaml
```

Helm in `WARNING: This chart is deprecated`: chart `trivy` 0.20.1 của Aqua đã được đánh dấu ngừng phát triển (xem [8.4](#84-nhận-xét-từ-manifest)).

## 8.2. Danh sách tài nguyên (7)

| Kind | Tên | Vai trò | Sinh từ values |
|---|---|---|---|
| ServiceAccount | `trivy` | Danh tính của server (không có IRSA) | `trivy.serviceAccount` |
| Secret | `trivy` | `GITHUB_TOKEN`, `TRIVY_TOKEN`, `TRIVY_USERNAME`, `TRIVY_PASSWORD`: **đều rỗng** | `trivy.gitHubToken`, `serverToken`, `registryUsername/Password` |
| ConfigMap | `trivy` | `TRIVY_LISTEN=0.0.0.0:9090`, `TRIVY_CACHE_DIR=/home/scanner/.cache/trivy`, `TRIVY_DEBUG=false`, `TRIVY_SKIP_DB_UPDATE=false`, `TRIVY_DB_REPOSITORY=ghcr.io/aquasecurity/trivy-db` | `trivy.*` |
| Role + RoleBinding | `trivy` | Role **không có rule nào** (server không cần quyền Kubernetes) | `rbac.create` |
| Service | `trivy` | ClusterIP `9090` (`trivy-http`), `sessionAffinity: ClientIP` | `service.*` |
| StatefulSet | `trivy` | Server, 1 replica | `replicaCount`, `persistence`, `resources`... |

Không có Ingress (`ingress.enabled: false`).

## 8.3. StatefulSet `trivy`

```
StatefulSet trivy (replicas 1, serviceAccountName trivy)
  securityContext: runAsUser 65534, runAsNonRoot, fsGroup 65534
  containers:
    main   docker.io/aquasec/trivy:0.68.2   args: [server]   cổng 9090
           envFrom: ConfigMap trivy + Secret trivy
           mounts: /tmp (emptyDir tmp-data), /home/scanner/.cache (PVC data)
  volumeClaimTemplates:
    data   gp3, 5Gi   → PVC data-trivy-0
```

| Thuộc tính | Giá trị render | Từ values |
|---|---|---|
| Image | `docker.io/aquasec/trivy:0.68.2` (tag lấy từ `appVersion` của chart) | `image.tag` (trống) |
| Lệnh | `trivy server`, cấu hình qua biến môi trường từ ConfigMap/Secret | Chart |
| Resources | requests `200m` / `512Mi`, limits `1` / `1Gi` | `resources` |
| liveness / readiness | `GET /healthz` cổng `trivy-http`, mỗi 10 giây, failure 10 / 3 | Chart |
| securityContext container | `privileged: false`, `readOnlyRootFilesystem: true` | `securityContext` |
| Lưu trữ | `volumeClaimTemplates` `data` 5Gi gp3 → PVC `data-trivy-0` chứa Trivy DB | `persistence.*` |

PVC tạo từ `volumeClaimTemplates`: đổi `persistence.size` trong values **không** đổi PVC đã có; muốn tăng thì `kubectl -n trivy patch pvc data-trivy-0` (gp3 cho phép mở rộng online), giống Gitaly ([GitLab 2.4](../gitlab/02-sizing.md#24-mở-rộng-ổ-gitaly-khi-gần-đầy)).

## 8.4. Nhận xét từ manifest

| # | Phát hiện | Mức | Đề xuất |
|---|---|---|---|
| 1 | `TRIVY_TOKEN` rỗng: server nhận request từ bất kỳ pod nào trong cụm | Trung bình | Đặt `trivy.existingSecret` (Secret có `TRIVY_TOKEN`), client thêm `--token`; NetworkPolicy chỉ cho namespace `jenkins`, `gitlab-runner` gọi cổng 9090 |
| 2 | Chart `trivy` bị đánh dấu deprecated | Trung bình | Chart vẫn chạy nhưng sẽ không được cập nhật. Phương án: giữ chart vendored và tự cập nhật `image.tag`; hoặc chuyển sang **Trivy Operator** (chart `aqua/trivy-operator`, vẫn được phát triển, có thể chạy chế độ server tích hợp); hoặc tự viết manifest nhỏ (StatefulSet + Service) theo render hiện tại |
| 3 | Image chưa ghim digest | Thấp | Ghim `aquasec/trivy:0.68.2@sha256:...` và kiểm tra chữ ký (cosign) |
| 4 | Role rỗng | Thông tin | Có thể tắt `rbac.create` |
| 5 | Non-root, rootfs chỉ đọc, không privileged | Tốt | Giữ nguyên |
| 6 | 1 replica | Thông tin | Đủ cho tải hiện tại; tăng replica cần bật Redis cache ([2.3](02-sizing.md#23-ví-dụ-cấu-hình)) |
