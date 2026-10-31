# 1. Kiến trúc Trivy và các tuỳ chọn cấu hình

[← Mục lục Trivy](README.md)

## 1.1. Tổng quan

```
 Pod build trên node CI (Jenkins agent)                          namespace trivy (node thường)
┌────────────────────────────────────────────┐                 ┌──────────────────────────────────┐
│ docker (dind): docker build → image.tar    │                 │ StatefulSet trivy (1 pod)        │
│                                            │                 │  aquasec/trivy:0.68.2 server     │
│ trivy (client, aquasec/trivy:0.68.2)       │   HTTP :9090    │  PVC 5Gi gp3: Trivy DB (cache)   │
│  1. đọc image.tar, liệt kê gói OS và thư   │ ──────────────► │  tự tải DB mới định kỳ           │
│     viện (jar, npm, pip...) trong các layer│  gửi danh sách  │  so khớp gói ↔ lỗ hổng           │
│  2. tải Java DB (để nhận diện jar)         │  gói, nhận về   │  non-root (65534), rootfs RO     │
│  3. nhận kết quả, ghi JSON/bảng, exit code │  lỗ hổng        └──────────────┬───────────────────┘
└──────────────┬─────────────────────────────┘                                │ tải DB (OCI)
               │ tải Java DB (OCI)                                            ▼
               ▼                                               ghcr.io/aquasecurity/trivy-db
     ghcr.io/aquasecurity/trivy-java-db                        (NVD, GitHub Advisory, Red Hat, Debian,
                                                                Ubuntu, Alpine, Amazon Linux, ...)
```

### Vì sao dùng chế độ client/server

| Chế độ | Cách chạy | Ưu | Nhược |
|---|---|---|---|
| Standalone (mặc định) | Mỗi lần quét tự tải Trivy DB (khoảng vài trăm MB nén) | Đơn giản | Pod build tạm thời: mỗi build tải lại DB, dễ bị giới hạn tải từ ghcr.io |
| **Client/server** (đang dùng) | Server giữ DB, client gửi danh sách gói để so khớp | DB tải một lần ở server, mọi build dùng chung; client nhẹ hơn | Thêm một dịch vụ phải chạy; Java DB vẫn ở client |

### Cơ sở dữ liệu lỗ hổng

| DB | Nội dung | Ở đâu |
|---|---|---|
| **Trivy DB** (`ghcr.io/aquasecurity/trivy-db`) | Lỗ hổng gói OS và thư viện ngôn ngữ, tổng hợp từ NVD, GitHub Security Advisory, các bản tin của distro (Red Hat, Debian, Ubuntu, Alpine, Amazon Linux, SUSE...), OSV... Phát hành lại vài giờ một lần | Server (PVC) |
| **Java DB** (`ghcr.io/aquasecurity/trivy-java-db`) | Ánh xạ checksum jar → groupId/artifactId/version, để nhận diện jar không có metadata Maven | **Client** (pod build), khoảng 3–4 GB khi giải nén |
| Checks bundle (`trivy-checks`) | Luật quét misconfiguration (IaC) | Client, khi dùng `--scanners misconfig` |

Trivy so khớp theo **dữ liệu của nhà phát hành distro** cho gói OS (ví dụ Debian đánh giá CVE nào ảnh hưởng gói nào, đã có bản sửa chưa), nên ít báo nhầm hơn so khớp thuần theo NVD.

### Các loại quét (`--scanners`)

| Scanner | Phát hiện | Đang dùng |
|---|---|---|
| `vuln` | Lỗ hổng đã biết (CVE/GHSA) trong gói OS và thư viện | ✅ |
| `secret` | Khoá, token, mật khẩu lọt trong file | ❌ (tắt để giảm thời gian và ổ tạm) |
| `misconfig` | Cấu hình sai trong Dockerfile, Kubernetes YAML, Helm, Terraform, CloudFormation | ❌ (nên dùng ở bước quét repo, [7.4](07-cach-dung-theo-loai-quet.md#74-iac-terraform-kubernetes-helm-dockerfile)) |
| `license` | License của gói | ❌ |

### Đối tượng quét (lệnh con)

| Lệnh | Quét |
|---|---|
| `trivy image` | Image (từ registry, Docker daemon hoặc file tar với `--input`) |
| `trivy fs` / `trivy repo` | Thư mục mã nguồn / repo Git (file khoá phụ thuộc: `pom.xml`, `package-lock.json`, `requirements.txt`...) |
| `trivy config` | IaC |
| `trivy sbom` | Một SBOM có sẵn (CycloneDX/SPDX) |
| `trivy k8s` | Tài nguyên và image đang chạy trong cụm |
| `trivy rootfs` / `trivy vm` | Hệ thống file gốc / máy ảo, AMI |

## 1.2. Cấu hình server (`helm-install/trivy-scanner/trivy/values.yaml`)

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `image.tag` | (trống → `appVersion` 0.68.2) | Client trong pipeline dùng **cùng phiên bản** (`aquasec/trivy:0.68.2`); lệch phiên bản client/server có thể lỗi giao thức |
| `replicaCount` | 1 | StatefulSet 1 pod |
| `persistence` | gp3, 5Gi, RWO | Lưu Trivy DB, không phải tải lại khi pod khởi động lại |
| `resources` | request 200m/512Mi, limit 1 CPU/1Gi | |
| `podSecurityContext` | uid 65534, `runAsNonRoot` | |
| `securityContext` | không privileged, `readOnlyRootFilesystem: true` | |
| `trivy.dbRepository` | `ghcr.io/aquasecurity/trivy-db` | Có thể trỏ về mirror nội bộ ([6.2](06-van-hanh-va-tu-dong-hoa.md#62-mirror-db-nội-bộ)) |
| `trivy.skipDBUpdate` | `false` | Server tự cập nhật DB |
| `trivy.gitHubToken` | trống | Chỉ cần nếu bị giới hạn tải từ GitHub |
| `trivy.serverToken` | **trống** | Không xác thực client; vì vậy không mở Ingress |
| `trivy.cache.redis` | tắt | Bật khi chạy nhiều replica server (cache dùng chung) |
| `service` | ClusterIP 9090, `sessionAffinity: ClientIP` | |
| `ingress.enabled` | `false` | Server không có xác thực, không đưa ra ALB |

## 1.3. Cấu hình client trong pipeline

Stage *Trivy Scan Image* của `Jenkinsfile` (`shopping-cart`):

```bash
trivy image --server http://trivy.trivy.svc.cluster.local:9090 --input image-shopping-cart-<tag>.tar --scanners vuln \
  --format json --output trivy-report.json --no-progress
trivy convert --format table --output trivy-report.txt trivy-report.json
trivy image --server http://trivy.trivy.svc.cluster.local:9090 --input image-shopping-cart-<tag>.tar --scanners vuln \
  --severity HIGH,CRITICAL --exit-code ${TRIVY_EXIT_CODE} --no-progress
```

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--server` | Chế độ client: so khớp lỗ hổng ở server |
| `--input <tar>` | Quét file tar do `docker save` tạo (workspace dùng chung giữa container `docker` và `trivy` trong pod), không cần đẩy image lên registry trước |
| `--scanners vuln` | Chỉ quét lỗ hổng |
| Lần 1: `--format json` (mọi mức) | Báo cáo đầy đủ, lưu làm artifact (S3) |
| `trivy convert --format table` | Bản dễ đọc từ JSON, không quét lại |
| Lần 2: `--severity HIGH,CRITICAL --exit-code` | **Cổng chặn**: in bảng HIGH/CRITICAL; exit code khác 0 làm build lỗi |
| `TRIVY_EXIT_CODE` | Hiện `'0'` (chỉ báo, không chặn) vì Spring Boot 1.5 có nhiều lỗ hổng; đặt `'1'` sau khi nâng cấp |

Trong `ci-lib` (`vars/ciImage.groovy`), cổng chặn luôn bật; ngoại lệ chỉ bằng `trivyWaiverUntil` (có hạn, build UNSTABLE thay vì FAILED) hoặc `.trivyignore` trong repo.

### Tuỳ chọn hay dùng khác

| Tuỳ chọn | Dùng khi |
|---|---|
| `--ignore-unfixed` | Chỉ chặn lỗ hổng đã có bản sửa (thường dùng cho cổng chặn, để không chặn những gì đội phát triển không sửa được) |
| `--ignorefile .trivyignore` | Danh sách CVE được chấp nhận (mặc định đọc `.trivyignore` ở thư mục hiện tại) |
| `--vex <file>` | Dùng VEX (OpenVEX/CycloneDX) để đánh dấu CVE không ảnh hưởng |
| `--ignore-policy <rego>` | Lọc kết quả bằng Rego (ví dụ bỏ qua theo package, theo đường dẫn) |
| `--pkg-types os,library` | Chỉ quét gói OS hoặc thư viện |
| `--format cyclonedx` / `spdx-json` | Sinh SBOM |
| `--cache-dir` | Thư mục cache (DB, Java DB, kết quả phân tích layer) |
| `--skip-java-db-update`, `--java-db-repository` | Dùng Java DB có sẵn hoặc từ mirror nội bộ |
