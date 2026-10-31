# 2. Sizing Nexus theo mức tải

[← Mục lục Nexus](README.md)

## 2.1. Nguyên tắc

- **Dung lượng là yếu tố đầu tiên**, không phải CPU. Docker image và cache proxy tăng rất nhanh: một image Java 300–500 MB, vài chục build mỗi ngày với tag khác nhau là vài GB/ngày nếu không có cleanup.
- **RAM quyết định độ ổn định**: heap JVM + direct memory + page cache của OS. Thiếu direct memory gây lỗi khi tải file lớn.
- **Database**: H2 (nhúng) phù hợp tải nhỏ; tải lớn, nhiều request đồng thời nên dùng **PostgreSQL** (RDS).
- **Một instance Nexus CE là một pod** (không chạy nhiều replica trên cùng dữ liệu). HA nhiều node cần bản **Pro** (chart `nxrm-ha`, PostgreSQL bắt buộc, blob store dùng chung S3/EFS).
- **Giới hạn Community Edition** (từ 3.77): Sonatype giới hạn số component và số request mỗi ngày cho CE (khoảng 40.000 component và 100.000 request/ngày theo công bố của Sonatype; kiểm tra lại theo phiên bản). Vượt ngưỡng kéo dài sẽ bị cảnh báo rồi chặn ghi. Xem mức dùng ở **Admin → System → Usage** (hoặc trang Usage Center tuỳ phiên bản). Hệ thống lớn cần tính đến bản Pro.

## 2.2. Ba mức cấu hình

| Hạng mục | Tải thấp (hiện tại) | Tải vừa | Enterprise (banking) |
|---|---|---|---|
| Quy mô | 1–3 team, < 50 build/ngày, vài định dạng | 5–20 team, 100–500 build/ngày, mọi định dạng | 50+ team, hàng nghìn build/ngày, nhiều site |
| Edition | CE | CE (theo dõi giới hạn) hoặc Pro | **Pro** (HA, SSO SAML, user token, staging, firewall) |
| Instance | 1 pod, request 1 CPU / 4Gi, limit 2 CPU / 4Gi | 1 pod, 4 CPU / 8–12Gi, node riêng | 3 node HA (`nxrm-ha`), mỗi node 8 CPU / 16–32Gi |
| JVM | heap 2G, direct 1.5G | heap 4–6G, direct 3–4G | heap 8G+, direct 6G+ (theo khuyến nghị Sonatype cho số repo/request) |
| Database | H2 nhúng | PostgreSQL (RDS `db.m7g.large`) | PostgreSQL Multi-AZ (`db.r7g.xlarge`+) |
| Blob store | PVC gp3 20Gi | PVC gp3 500Gi–1Ti hoặc **S3** | **S3** (dung lượng không giới hạn, lifecycle, replication) |
| Thư mục làm việc `/nexus-data` | Chung với blob store | PVC 50–100Gi (DB nếu H2, log, cache) | PVC/EFS theo node |
| Cleanup | Thủ công | Cleanup policy cho mọi repo | Cleanup policy + staging/promotion |
| Sẵn sàng | Mất pod = dừng vài phút; mất volume = mất dữ liệu nếu không backup | Snapshot hằng ngày, khôi phục vài giờ | HA nhiều node, DR region khác |

### Ước tính dung lượng

| Thành phần | Công thức gợi ý |
|---|---|
| Docker hosted | số app × số tag giữ lại × kích thước image (layer dùng chung giữa tag giảm đáng kể) |
| Docker proxy | số image nền khác nhau × kích thước (thường 10–100 GB) |
| Maven/npm/PyPI proxy | 5–50 GB tuỳ số dự án |
| Maven/npm/PyPI hosted | Nhỏ với release; snapshot tăng nhanh nếu không cleanup |
| apt/yum proxy | 10–100 GB (chỉ cache gói đã tải, không mirror toàn bộ) |
| Dự phòng | +30% và cảnh báo ở 80% |

Với cấu hình hiện tại (20Gi chung cho DB, log và blob), **cần tăng ngay khi bắt đầu dùng Docker proxy hoặc proxy gói Linux**, xem [2.4](#24-mở-rộng-dung-lượng).

## 2.3. Ví dụ values cho mức tải vừa

```yaml
nexus:
  env:
    - name: INSTALL4J_ADD_VM_PARAMS
      value: "-Xms4g -Xmx4g -XX:MaxDirectMemorySize=4g -Djava.util.prefs.userRoot=/nexus-data/javaprefs"
  resources:
    requests: { cpu: "2", memory: 10Gi }
    limits:   { cpu: "4", memory: 10Gi }   # heap 4g + direct 4g + ~2g cho JVM/OS
  nodeSelector: { workload: tools }
persistence:
  storageClass: gp3
  storageSize: 500Gi
```

PostgreSQL thay cho H2 (CE hỗ trợ PostgreSQL từ các bản 3.7x): khai báo qua biến môi trường `NEXUS_DATASTORE_NEXUS_JDBCURL`, `NEXUS_DATASTORE_NEXUS_USERNAME`, `NEXUS_DATASTORE_NEXUS_PASSWORD` (lấy từ Secret). Chuyển dữ liệu H2 → PostgreSQL theo công cụ **database migrator** của Sonatype (Nexus phải dừng, sao lưu trước).

Blob store S3: tạo bucket (Terraform, SSE-KMS, chặn public, versioning), giữ IRSA `eks-nexus-role` (sửa tên bucket trong `nexus-helm.tf` cho khớp), rồi trên giao diện **Blob Stores → Create → S3**, để trống access key (dùng IAM role của pod). Repo mới chọn blob store S3; repo cũ giữ blob store cũ.

## 2.4. Mở rộng dung lượng

PVC `nexus-data` là PVC độc lập của chart (không phải `volumeClaimTemplates`), StorageClass `gp3` cho phép mở rộng online, nên làm giống Jenkins ([Jenkins 5.13](../jenkins/05-huong-dan-trien-khai.md#513-mở-rộng-volume-jenkins_home-khi-gần-đầy)):

```bash
kubectl -n nexus exec deploy/nexus -- df -h /nexus-data
VOL=$(kubectl get pv $(kubectl -n nexus get pvc nexus-data -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 create-snapshot --volume-id "$VOL" --description "nexus-data before resize $(date +%F)" --region ap-southeast-1
```

Sửa `persistence.storageSize: 20Gi` → `100Gi` trong `values.yaml`, commit, rồi:

```bash
helm upgrade nexus ./helm-install/nexus/nexus-repository-manager -n nexus
kubectl -n nexus get pvc nexus-data -w
kubectl -n nexus exec deploy/nexus -- df -h /nexus-data
```

Chỉ tăng được; mỗi volume EBS 6 giờ mới sửa được một lần. Trước khi tăng, chạy cleanup và task *Compact blob store* (xoá thật các blob đã đánh dấu xoá) để chắc dung lượng là thật sự cần.

## 2.5. Theo dõi để biết khi nào cần nâng cấp

| Chỉ số | Ngưỡng gợi ý | Hành động |
|---|---|---|
| Dung lượng `/nexus-data` | > 80% | Cleanup, compact, mở rộng PVC, chuyển blob sang S3 |
| Heap JVM | > 80% kéo dài, GC dài | Tăng heap và memory limit |
| `OutOfDirectMemoryError` trong log | Có | Tăng `MaxDirectMemorySize` |
| Thời gian phản hồi (log request, ALB `TargetResponseTime`) | p95 > 2 giây | Tăng CPU; chuyển H2 → PostgreSQL |
| Mức dùng CE (component, request/ngày) | > 70% giới hạn | Cleanup; cân nhắc Pro |
| Proxy bị auto-block (remote không phản hồi) | Có | Kiểm tra mạng ra Internet, rate limit Docker Hub |

Nexus có endpoint metric `/service/metrics/prometheus` (cần quyền `nx-metrics-all`) và trạng thái `/service/rest/v1/status/check`.

## 2.6. Tính sẵn sàng của cấu hình hiện tại

| Thành phần | Điểm lỗi đơn | Ảnh hưởng | Cách giảm |
|---|---|---|---|
| Pod nexus (1 replica) | Có | Build không tải được thư viện/image trong lúc pod khởi động lại (vài phút) | Chấp nhận với CE; Pro: HA |
| PVC EBS (1 AZ) | Có | Mất volume là mất toàn bộ repo hosted và cấu hình | Snapshot hằng ngày; sao lưu DB qua task; blob S3 |
| Docker Hub (qua proxy) | — | Rate limit khi pull ẩn danh | Đăng nhập Docker Hub trong cấu hình proxy |

Khi Nexus dừng, các build đã có cache trên node CI (image) vẫn chạy được một phần; build cần tải thư viện mới sẽ lỗi. Đây là lý do Nexus phải được giám sát như một dịch vụ quan trọng.
