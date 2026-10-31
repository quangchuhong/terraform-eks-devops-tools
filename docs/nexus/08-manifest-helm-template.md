# 8. Manifest Nexus sinh từ `helm template`

[← Mục lục Nexus](README.md) · [Hướng dẫn chung về `helm template`](../helm-template/README.md)

## 8.1. Render

```bash
./helm-install/render.sh nexus
```

Tương đương:

```bash
helm template nexus ./helm-install/nexus/nexus-repository-manager -n nexus --kube-version 1.34.0 > helm-install/rendered/nexus.yaml
```

Kèm theo là manifest thường `helm-install/nexus/manifests/nexus-docker.yaml` (áp bằng `kubectl apply`, không qua Helm).

## 8.2. Danh sách tài nguyên

**Từ chart (7):**

| Kind | Tên | Vai trò | Sinh từ values |
|---|---|---|---|
| ServiceAccount | `nexus` | Annotation IRSA `...:role/eks-nexus-role` (blob store S3, ECR) | `serviceAccount.*` |
| PersistentVolumeClaim | `nexus-data` | `/nexus-data`: DB H2, blob store, log; gp3, **20Gi**, RWO | `persistence.*` |
| Service | `nexus` | ClusterIP `8081` (`nexus-ui`) | `service.*`, `nexus.nexusPort` |
| Deployment | `nexus` | 1 replica, strategy `Recreate` | `nexus.*`, `deployment.*`, `deploymentStrategy` |
| Ingress | `nexus` | `nexus.gitlabonlinecom.click` → `nexus:8081`, ALB group `alb-apps`, health check `/` (200-399) | `ingress.*` |
| Pod | `nexus-test-connection`, `nexus-test-check-logs` | Test của chart, chỉ khi `helm test nexus` | Chart |

**Từ `manifests/nexus-docker.yaml` (4):**

| Kind | Tên | Vai trò |
|---|---|---|
| Service | `nexus-docker` | ClusterIP 8000 (hosted), 8001 (group), 8002 (proxy), chọn pod theo label của chart (`app.kubernetes.io/name: nexus-repository-manager`, `instance: nexus`) |
| Ingress | `nexus-docker-internal` | `docker-internal.gitlabonlinecom.click` → 8000 |
| Ingress | `nexus-docker` | `docker.gitlabonlinecom.click` → 8001 |
| Ingress | `nexus-docker-proxy` | `docker-proxy.gitlabonlinecom.click` → 8002 |

Ba Ingress Docker dùng health check `/v2/`, `success-codes: "200,401"` (registry trả 401 khi chưa đăng nhập).

## 8.3. Deployment `nexus`

```
Deployment nexus (replicas 1, strategy Recreate, serviceAccountName nexus)
  securityContext: runAsUser 200, runAsGroup 200, fsGroup 200
  initContainers:
    fix-permissions   busybox:1.36            chạy root: chown -R 200:200 /nexus-data
  containers:
    nexus-repository-manager   sonatype/nexus3:3.85.0   cổng 8081
  volumes:
    nexus-repository-manager-data  ← PVC nexus-data, mount /nexus-data
```

| Thuộc tính | Giá trị render | Từ values |
|---|---|---|
| Image | `sonatype/nexus3:3.85.0` | `image.tag` |
| Resources | requests `1` CPU / `4Gi`, limits `2` / `4Gi` | `nexus.resources` |
| Env `INSTALL4J_ADD_VM_PARAMS` | `-Xms2048m -Xmx2048m -XX:MaxDirectMemorySize=1536m -Djava.util.prefs.userRoot=/nexus-data/javaprefs -Dnexus.scripts.allowCreation=true` | `nexus.env` |
| Env `NEXUS_SECURITY_RANDOMPASSWORD` | `true` | `nexus.env` |
| livenessProbe | `GET /` cổng 8081, chờ 300 giây, mỗi 20 giây, failure 6 | `nexus.livenessProbe` |
| readinessProbe | `GET /`, chờ 60 giây, mỗi 20 giây, failure 6 | `nexus.readinessProbe` |
| securityContext container | `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop `ALL`, seccomp `RuntimeDefault` | Chart |

Vì sao `Recreate`: PVC là `ReadWriteOnce` (EBS chỉ gắn vào một node). Với `RollingUpdate`, pod mới sẽ chờ volume mãi vì pod cũ còn giữ. Đổi lại, mỗi lần upgrade Nexus gián đoạn vài phút.

Bộ nhớ: heap 2Gi + direct memory 1,5Gi + phần JVM/OS ≈ 4Gi, vừa đúng limit 4Gi. Tăng heap/direct thì phải tăng `resources` tương ứng.

## 8.4. Nhận xét từ manifest

| # | Phát hiện | Mức | Đề xuất |
|---|---|---|---|
| 1 | PVC 20Gi dùng chung DB, log và blob store | Cao (khi dùng Docker/OS proxy) | Tăng `persistence.storageSize` ([2.4](02-sizing.md#24-mở-rộng-dung-lượng)) hoặc blob store S3 |
| 2 | `-Dnexus.scripts.allowCreation=true` | Trung bình | Bỏ nếu không dùng Groovy script API |
| 3 | Init container chạy root (chỉ `chown`), không có resources | Thấp | Chấp nhận (cần để sửa quyền); đặt resources nhỏ nếu namespace có LimitRange/quota |
| 4 | Template `deployment.yaml` của chart có ký tự **tab** thừa sau `mountPath: /nexus-data` | Thấp | Kubernetes chấp nhận nên deploy chạy bình thường; một số công cụ đọc YAML (PyYAML, một số linter) báo lỗi. Có thể xoá tab trong template của chart vendored |
| 5 | Liveness chờ 300 giây | Thông tin | Cần cho lần khởi động đầu; có thể chuyển sang `startupProbe` để phát hiện treo sớm hơn ở các lần sau |
| 6 | Docker connector nằm ngoài chart | Thông tin | Nhớ `kubectl apply -f helm-install/nexus/manifests/` sau khi cài/cài lại chart |
| 7 | Non-root, drop capabilities, seccomp | Tốt | Giữ nguyên |
