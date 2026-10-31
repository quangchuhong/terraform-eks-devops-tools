# 5. Hướng dẫn cấu hình đã triển khai

[← Mục lục Nexus](README.md)

## 5.1. Điều kiện trước

| Điều kiện | Ghi chú |
|---|---|
| Cụm EKS, AWS Load Balancer Controller, StorageClass `gp3` | Từ Terraform |
| IAM role `eks-nexus-role` (IRSA cho `nexus/nexus`) | `nexus-helm.tf` |
| Bản ghi DNS `nexus`, `docker`, `docker-internal`, `docker-proxy` | `app_hostnames` + `enable_dns_records = true` |
| `kubectl`, `helm`, `curl` trên máy quản trị | |

## 5.2. Các file cấu hình

| File | Nội dung |
|---|---|
| `helm-install/nexus/nexus-repository-manager/` | Chart (bản tải về) + `values.yaml` đã chỉnh |
| `helm-install/nexus/manifests/nexus-docker.yaml` | Service `nexus-docker` (8000/8001/8002) + 3 Ingress Docker |
| `helm-install/nexus/bootstrap.sh` | Docker realm, repo Docker/npm/PyPI, role `ci-role`, user `ci-jenkins`, Secret `jenkins/nexus-ci` |
| `helm-install/nexus/repos-extra.sh` | Repo cho mọi công nghệ ([phần 7](07-cau-hinh-theo-cong-nghe.md)), role `read-all` |
| `nexus-helm.tf` | IAM role IRSA `eks-nexus-role` |

## 5.3. Cài đặt

```bash
helm upgrade --install nexus ./helm-install/nexus/nexus-repository-manager -n nexus --create-namespace --timeout 15m
kubectl -n nexus get pods -w
kubectl apply -f helm-install/nexus/manifests/
kubectl -n nexus get ingress
```

Lần khởi động đầu mất 3–5 phút (khởi tạo DB H2). Pod `nexus-...` phải `1/1 Running`; 4 Ingress (`nexus`, `nexus-docker`, `nexus-docker-internal`, `nexus-docker-proxy`) có cùng ADDRESS với ALB của GitLab.

## 5.4. Đăng nhập lần đầu

```bash
kubectl -n nexus exec deploy/nexus -- cat /nexus-data/admin.password; echo
```

Mở http://nexus.gitlabonlinecom.click → **Sign in** với `admin` và mật khẩu trên. Wizard đầu tiên:

1. Đổi mật khẩu `admin` (lưu vào password manager, không dán vào chat/tài liệu). File `admin.password` tự xoá.
2. **Anonymous access:** chọn *Disable* (khuyến nghị). Nếu bật, chỉ nên cho đọc.
3. Bỏ qua phần usage/telemetry tuỳ chính sách.

## 5.5. Bootstrap cho CI

```bash
./helm-install/nexus/bootstrap.sh
```

Script hỏi mật khẩu `admin` (không hiện khi gõ), mở port-forward và gọi REST API:

| Bước | Kết quả |
|---|---|
| Realm | Thêm **Docker Bearer Token Realm** |
| Docker | `docker-hosted` (:8000, `allow`), `docker-proxy` → Docker Hub (:8002), `docker-group` (:8001) |
| npm, PyPI | `npm-proxy`/`npm-hosted`/`npm-group`, `pypi-proxy`/`pypi-hosted`/`pypi-group` (`allow_once`) |
| Role | `ci-role` (đọc group, ghi hosted) |
| User | `ci-jenkins` với mật khẩu ngẫu nhiên 32 ký tự |
| Secret | `jenkins/nexus-ci` (`username`, `password`), Jenkins đọc qua JCasC thành `nexus-creds` và `docker-user-internal` |

Chạy lại bất kỳ lúc nào: repo đã có được giữ nguyên, quyền `ci-role` được cập nhật, mật khẩu `ci-jenkins` được **xoay vòng** (sau đó `kubectl -n jenkins delete pod jenkins-0` để Jenkins nạp lại). Chỉ thêm repo/quyền, không đổi mật khẩu:

```bash
ROTATE_CI_PASSWORD=no ./helm-install/nexus/bootstrap.sh
```

## 5.6. Repo cho các công nghệ khác

```bash
./helm-install/nexus/repos-extra.sh
```

Tạo Docker proxy cho ghcr.io, quay.io, registry.k8s.io, public.ecr.aws, mcr.microsoft.com, gcr.io (gộp vào `docker-group`); Gradle Plugin Portal (gộp vào `maven-public`); Conan, vcpkg cache; apt/yum/apk; Chocolatey, PowerShell Gallery; kho công cụ AWS/GCP/Azure/HashiCorp; `tools-hosted`; role `read-all`. Chi tiết cách dùng từng loại ở [phần 7](07-cau-hinh-theo-cong-nghe.md).

Script báo `FAIL` cho định dạng không có trong phiên bản Nexus đang chạy hoặc khi remote sai, và vẫn chạy tiếp các repo khác.

## 5.7. Kiểm tra

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://nexus.gitlabonlinecom.click/service/rest/v1/status
curl -s -o /dev/null -w "%{http_code}\n" http://docker.gitlabonlinecom.click/v2/
kubectl -n jenkins get secret nexus-ci -o jsonpath='{.data.username}' | base64 -d; echo
```

Mong đợi: `200`; `401` (registry yêu cầu đăng nhập); `ci-jenkins`.

Kiểm tra đầu-cuối bằng pipeline: build `shopping-cart` tải dependency qua `maven-public`, `mvn deploy` lên `maven-snapshots`, push image lên `docker-internal.gitlabonlinecom.click/dev-backend/shopping-cart`. Trên giao diện: **Browse → maven-snapshots / docker-hosted** thấy artifact mới.

## 5.8. Nâng cấp

| Bước | Lệnh / ghi chú |
|---|---|
| 1. Đọc release notes | Lưu ý thay đổi DB, Java, định dạng bị bỏ |
| 2. Sao lưu | Task *Export databases for backup* + snapshot EBS ([6.4](06-van-hanh-va-tu-dong-hoa.md#64-sao-lưu-và-khôi-phục)) |
| 3. Đổi `image.tag` | Trong `values.yaml`, commit |
| 4. Upgrade | `helm upgrade nexus ./helm-install/nexus/nexus-repository-manager -n nexus --timeout 15m` (strategy `Recreate`: gián đoạn vài phút) |
| 5. Kiểm tra | Đăng nhập, `status`, pull/push thử, build pipeline |

**Không hạ phiên bản**: dữ liệu `/nexus-data` sau khi nâng cấp (hoặc tạo bởi 3.85.0) không chạy được trên bản cũ hơn. Bản cũ hơn 3.71 còn dùng OrientDB (hết hỗ trợ), không quay lại.

## 5.9. Sao lưu, mở rộng dung lượng, gỡ cài đặt

- Sao lưu và khôi phục: [6.4](06-van-hanh-va-tu-dong-hoa.md#64-sao-lưu-và-khôi-phục).
- Mở rộng PVC `nexus-data`: [2.4](02-sizing.md#24-mở-rộng-dung-lượng).
- Gỡ: `helm -n nexus uninstall nexus` và `kubectl delete -f helm-install/nexus/manifests/`. PVC `nexus-data` bị xoá cùng release (PVC của chart), **volume EBS bị xoá theo** (`reclaimPolicy: Delete`): snapshot trước, hoặc đặt PV về `Retain` (`kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`).

## 5.10. Sự cố đã gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `helm template` không ra manifest đúng | `values.yaml` sai cấu trúc so với chart | Viết lại values theo `values.yaml` gốc của chart |
| Pod `CrashLoopBackOff`, exit 255; log: `AccessDenied` khi tạo `/nexus-data/etc/...` | Mount `nexus.properties` bằng subPath làm kubelet tạo `/nexus-data/etc` thuộc root; Nexus chạy uid 200 | `nexus.properties.override: false` (đặt thuộc tính qua JVM option) + init container `chown -R 200:200 /nexus-data` |
| Cảnh báo bảo mật OrientDB | Bản cũ dùng OrientDB (hết hỗ trợ, CVE nghiêm trọng) | Dùng 3.85.0 (H2); không quay lại bản cũ |
| `EntityAlreadyExists: Role with name eks-nexus-role` khi `terraform apply` | Role còn từ lần cài trước, không có trong state | `terraform import aws_iam_role.nexus eks-nexus-role` (và các policy đi kèm) |
| Ingress Docker `unhealthy` trên ALB | `/v2/` trả `401` khi chưa đăng nhập | `success-codes: "200,401"`, `healthcheck-path: /v2/` |
| `docker login`: `http: server gave HTTP response to HTTPS client` | Registry HTTP | Thêm hostname vào `insecure-registries` (Docker daemon) hoặc `--insecure-registry` (dind); containerd: `hosts.toml`. Giải pháp lâu dài: HTTPS |
| `docker pull` qua `docker-proxy`: `toomanyrequests` | Rate limit Docker Hub cho pull ẩn danh | Khai báo tài khoản Docker Hub trong cấu hình `docker-proxy` (HTTP → Authentication) |
| `ci-jenkins` không push được vào repo mới | `ci-role` chưa có quyền trên repo đó | Thêm privilege vào `ci-role` (bootstrap) rồi chạy lại với `ROTATE_CI_PASSWORD=no` |
