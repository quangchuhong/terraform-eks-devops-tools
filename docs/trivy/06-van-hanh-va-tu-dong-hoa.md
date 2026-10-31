# 6. Vận hành và tự động hoá

[← Mục lục Trivy](README.md)

## 6.1. Lịch vận hành

| Tần suất | Việc |
|---|---|
| Hằng ngày | DB trên server được cập nhật (log server); không có build lỗi do tải DB |
| Hằng tuần | Xem tổng số HIGH/CRITICAL theo app (Dependency-Track/DefectDojo hoặc báo cáo JSON); ngoại lệ sắp hết hạn |
| Hằng tháng | Nâng Trivy (server + client cùng lúc); rà soát `.trivyignore` của các repo |
| Hằng quý | Quét nội bộ toàn bộ image đang chạy và cụm (`trivy k8s`) làm bằng chứng PCI DSS 11.3.1 |

## 6.2. Mirror DB nội bộ

Mục đích: không phụ thuộc ghcr.io, nhanh hơn, chạy được trong mạng cô lập.

**Cách 1: qua Nexus `ghcr-proxy`** (đã có trong `docker-group` sau khi chạy `repos-extra.sh`). DB của Trivy là artifact OCI trên ghcr.io, nên trỏ Trivy về Nexus:

```bash
trivy image --db-repository docker.gitlabonlinecom.click/aquasecurity/trivy-db:2 \
  --java-db-repository docker.gitlabonlinecom.click/aquasecurity/trivy-java-db:1 ...
```

Server: `trivy.dbRepository: "docker.gitlabonlinecom.click/aquasecurity/trivy-db"`. Cần credential Nexus (`TRIVY_USERNAME`/`TRIVY_PASSWORD` hoặc `trivy.existingSecret`) và cấu hình registry HTTP. Kiểm tra Nexus phiên bản đang chạy proxy được artifact OCI (không phải image) trước khi dùng cho production.

**Cách 2: đồng bộ theo lịch bằng `oras`** sang registry nội bộ (Nexus `docker-hosted` hoặc ECR), chạy CronJob mỗi 6 giờ:

```bash
oras copy ghcr.io/aquasecurity/trivy-db:2 <registry-nội-bộ>/security/trivy-db:2
oras copy ghcr.io/aquasecurity/trivy-java-db:1 <registry-nội-bộ>/security/trivy-java-db:1
```

**Cache Java DB cho pod build:** thay vì mỗi pod tải lại, dùng volume cache trên node (`hostPath` chỉ đọc, hoặc PVC EFS dùng chung) mount vào `--cache-dir`, cập nhật bằng một Job định kỳ (`trivy image --download-java-db-only --cache-dir /cache`), client chạy với `--skip-java-db-update`.

## 6.3. SBOM và Dependency-Track

Sinh SBOM cho mỗi image trong pipeline (thêm vào stage Trivy):

```bash
trivy image --server http://trivy.trivy.svc.cluster.local:9090 --input image.tar \
  --format cyclonedx --output sbom.cdx.json --no-progress
```

Lưu `sbom.cdx.json` cùng báo cáo (artifact S3). Upload lên **OWASP Dependency-Track** (cài bằng Helm, miễn phí):

```bash
curl -sf -X POST "$DTRACK_URL/api/v1/bom" -H "X-Api-Key: $DTRACK_API_KEY" \
  -F "autoCreate=true" -F "projectName=shopping-cart" -F "projectVersion=$POM_VERSION" \
  -F "bom=@sbom.cdx.json"
```

Dependency-Track theo dõi liên tục: khi có CVE mới ảnh hưởng thành phần trong SBOM đã upload, nó cảnh báo (email/Slack/webhook) mà không cần build lại. API key lấy từ Jenkins credential.

## 6.4. Quét liên tục trong cụm (Trivy Operator)

Trivy Operator chạy trong cụm, tự quét workload và lưu kết quả thành CRD (`VulnerabilityReport`, `ConfigAuditReport`, `ExposedSecretReport`, `RbacAssessmentReport`, `ClusterComplianceReport`).

```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update aqua
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --set trivy.mode=ClientServer \
  --set trivy.serverURL=http://trivy.trivy.svc.cluster.local:9090
kubectl get vulnerabilityreports -A
kubectl get configauditreports -A
```

- `ClientServer` dùng lại Trivy server đang có, không tải DB ở mỗi job quét.
- Metric Prometheus của operator đưa lên Grafana (số CVE theo namespace/mức độ).
- Ghim phiên bản chart (`--version`) và cấu hình node chạy job quét (không chạy trên node GitLab/Jenkins controller).

Với image trên ECR: bật **ECR Enhanced scanning** (Amazon Inspector) để quét liên tục, không cần chạy thêm gì trong cụm.

## 6.5. Runbook sự cố

| Tình huống | Kiểm tra | Xử lý |
|---|---|---|
| Client báo không kết nối được server | `kubectl -n trivy get pods`; `kubectl -n trivy logs statefulset/trivy` | Server khởi động lại/đang tải DB: chờ; tạm chạy client standalone (bỏ `--server`) |
| `failed to download vulnerability DB` / `TOOMANYREQUESTS` | Mạng ra ghcr.io | Mirror nội bộ; `gitHubToken`; kiểm tra NAT/proxy |
| DB cũ (log `DB ... is older than`) | PVC, quyền ghi | Xoá cache DB trên PVC và khởi động lại pod (`kubectl -n trivy delete pod trivy-0`) |
| Pod build Evicted ở stage Trivy | Ổ tạm node | Request `ephemeral-storage`; cache Java DB; node lớn hơn |
| Kết quả khác nhau giữa hai lần quét | DB cập nhật giữa hai lần | Bình thường; ghi lại `trivy --version` và thời điểm DB trong báo cáo (`.Trivy.DB` trong JSON tuỳ phiên bản) |
| Báo nhầm (false positive) | Đối chiếu advisory của distro/thư viện | `.trivyignore`/VEX có lý do và người duyệt; báo lỗi lên dự án Trivy nếu sai dữ liệu |
