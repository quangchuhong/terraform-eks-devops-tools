# 6. Vận hành và tự động hoá Nexus (enterprise)

[← Mục lục Nexus](README.md)

## 6.1. Mô hình vận hành

| Nguyên tắc | Áp dụng |
|---|---|
| Cấu hình là code | Repo, role, user máy tạo bằng script REST (`bootstrap.sh`, `repos-extra.sh`) hoặc Terraform provider `datadrivers/nexus`; không tạo tay trên giao diện cho môi trường thật |
| Đọc qua group, ghi vào hosted | Thống nhất cho mọi định dạng |
| Dung lượng có kế hoạch | Cleanup policy cho **mọi** repo ngay khi tạo; quota blob store |
| Sao lưu phải khôi phục được | Diễn tập hằng quý |

| Vai trò | Trách nhiệm |
|---|---|
| Platform/DevOps | Cài đặt, nâng cấp, repo, cleanup, sao lưu, giám sát |
| Security | Duyệt nguồn proxy, routing rule, quyền, xoay vòng tài khoản máy |
| Team phát triển | Dùng đúng group/hosted, không lưu secret trong cấu hình client |

SLO gợi ý: khả dụng 99,5%/tháng; p95 tải artifact < 1 giây (đã cache); RPO 24 giờ; RTO 4 giờ.

## 6.2. Lịch vận hành định kỳ

| Tần suất | Việc |
|---|---|
| **Hằng ngày** | Task backup DB chạy thành công; dung lượng `/nexus-data`; proxy bị auto-block |
| **Hằng tuần** | Task cleanup + compact chạy đúng; xem repo tăng nhanh; log lỗi |
| **Hằng tháng** | Bản vá Nexus; rà soát user/role; kiểm tra mức dùng CE |
| **Hằng quý** | Diễn tập khôi phục; rà soát danh sách proxy (nguồn còn cần thiết, còn tin cậy) |
| **Hằng năm** | Xoay vòng mật khẩu `admin`; đánh giá sizing, cân nhắc Pro/PostgreSQL/S3 |

## 6.3. Cleanup và task

### Cleanup policy (Repository → Cleanup Policies)

| Policy | Áp dụng cho | Tiêu chí gợi ý |
|---|---|---|
| `snapshots-30d` | `maven-snapshots` | Component không được tải trong 30 ngày hoặc publish > 30 ngày |
| `docker-hosted-90d` | `docker-hosted` | Không được tải trong 90 ngày (giữ image đang chạy production bằng cách pull định kỳ hoặc tag riêng không xoá) |
| `proxy-unused-60d` | Mọi proxy (Docker, Maven, npm, PyPI, apt, yum...) | Không được tải trong 60 ngày |
| `tmp-cache-14d` | `vcpkg-cache` | Publish > 14 ngày |

Gắn policy: Repository → chọn repo → *Cleanup policies*. Policy chỉ **đánh dấu xoá**; cần task để giải phóng dung lượng.

### Task (System → Tasks)

| Task | Lịch gợi ý | Mục đích |
|---|---|---|
| *Admin - Cleanup repositories using their associated policies* | Hằng ngày 01:00 | Áp dụng cleanup policy (mặc định đã có) |
| *Docker - Delete unused manifests and images* | Hằng ngày 02:00 | Xoá layer không còn manifest nào tham chiếu |
| *Docker - Delete incomplete uploads* | Hằng ngày | Dọn upload dở |
| *Maven - Delete unused SNAPSHOT* | Hằng ngày | Bổ sung cho cleanup policy |
| *Admin - Compact blob store* | Hằng ngày 03:00 (sau các task trên) | **Xoá thật** blob đã đánh dấu, giải phóng dung lượng |
| *Admin - Export databases for backup* | Hằng ngày 00:30 | Sao lưu DB ra `/nexus-data/backup` ([6.4](#64-sao-lưu-và-khôi-phục)) |
| *Repair - Rebuild repository search* | Khi tìm kiếm sai | Sửa index |

## 6.4. Sao lưu và khôi phục

Nexus gồm hai phần phải sao lưu **cùng thời điểm**: **database** (cấu hình, metadata) và **blob store** (file).

| Phần | Cách | Tần suất |
|---|---|---|
| Database (H2) | Task *Export databases for backup* → thư mục `/nexus-data/backup` (trên PVC) | Hằng ngày |
| Blob store + DB export | **Snapshot EBS** PVC `nexus-data` (AWS Backup/DLM), chạy **sau** task export | Hằng ngày, giữ 7–30 bản |
| Blob store S3 (khi dùng) | Versioning + (tuỳ chọn) Cross-Region Replication | Liên tục |
| Cấu hình code | Git (values, manifests, scripts) | Mỗi thay đổi |

Thứ tự đảm bảo nhất quán: export DB trước, sau đó snapshot blob store. Khôi phục dùng DB export cùng ngày hoặc cũ hơn blob store (blob thừa không sao, blob thiếu thì component lỗi).

### Khôi phục toàn bộ

1. Dừng Nexus: `kubectl -n nexus scale deploy nexus --replicas=0`.
2. Tạo volume từ snapshot EBS và gắn vào PVC `nexus-data` (quy trình như [Jenkins 5.9](../jenkins/05-huong-dan-trien-khai.md#khôi-phục-rollback-từ-snapshot), thay namespace `nexus`, PVC `nexus-data`, deployment `nexus`).
3. Nếu cần khôi phục DB từ export: chép file từ `/nexus-data/backup/` vào `/nexus-data/restore-from-backup/` (pod tạm gắn PVC), xoá thư mục DB cũ theo hướng dẫn của Sonatype cho H2.
4. Bật lại: `kubectl -n nexus scale deploy nexus --replicas=1`; kiểm tra đăng nhập, browse, pull/push.
5. Chạy *Repair - Reconcile component database from blob store* nếu thấy component lỗi.

### Khôi phục một artifact bị xoá nhầm

Repo hosted không có thùng rác. Nếu blob chưa bị compact: khôi phục bằng task *Repair - Reconcile...* hoặc soft-deleted blob (tuỳ phiên bản). Nếu đã compact: khôi phục từ snapshot ra một Nexus tạm, tải artifact về rồi upload lại. Vì vậy nên **chạy compact sau backup**.

## 6.5. Tự động hoá

### Cấu hình bằng code

| Cách | Khi dùng |
|---|---|
| Script REST (`bootstrap.sh`, `repos-extra.sh`) | Đang dùng; đơn giản, chạy lại được |
| Terraform provider `datadrivers/nexus` | Muốn quản lý repo, role, user, cleanup policy, blob store, routing rule bằng Terraform (có plan, có state) |

Ví dụ Terraform:

```hcl
terraform {
  required_providers {
    nexus = { source = "datadrivers/nexus" }
  }
}

provider "nexus" {
  url      = "http://nexus.gitlabonlinecom.click"
  username = "admin"
  # password từ biến môi trường NEXUS_PASSWORD
}

resource "nexus_repository_maven_hosted" "payments_releases" {
  name   = "payments-releases"
  online = true
  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
    write_policy                   = "ALLOW_ONCE"
  }
  maven {
    version_policy = "RELEASE"
    layout_policy  = "STRICT"
  }
}
```

### Giám sát và cảnh báo

| Nguồn | Cảnh báo |
|---|---|
| `kubelet_volume_stats_*` (PVC `nexus-data`) | > 80% |
| `/service/rest/v1/status/check` (Blackbox/CloudWatch Synthetics) | Không `200` trong 5 phút |
| `/service/metrics/prometheus` (user có `nx-metrics-all`) | Heap > 85%, thread bị block |
| Log `nexus.log` | `OutOfDirectMemoryError`, `auto-blocked` |
| ALB (CloudWatch) | 5xx > 1% cho host `nexus`/`docker*` |
| Task | Task backup/compact thất bại (email từ Nexus: System → Email Server + task alert) |

### Xoay vòng tài khoản máy

`bootstrap.sh` (không có `ROTATE_CI_PASSWORD=no`) đổi mật khẩu `ci-jenkins` và cập nhật Secret; sau đó khởi động lại Jenkins. Có thể đặt lịch hằng quý.

## 6.6. Runbook sự cố

| Tình huống | Kiểm tra | Xử lý |
|---|---|---|
| **Giao diện/registry 502/503** | `kubectl -n nexus get pods`; `kubectl -n nexus logs deploy/nexus --tail=100` | Pod đang khởi động (3–5 phút); `CrashLoopBackOff`: xem log (quyền thư mục, hết dung lượng, hết bộ nhớ) |
| **Đầy dung lượng** | `kubectl -n nexus exec deploy/nexus -- df -h /nexus-data` | Chạy cleanup + compact; mở rộng PVC ([2.4](02-sizing.md#24-mở-rộng-dung-lượng)); Nexus chuyển chế độ chỉ đọc khi gần đầy đĩa |
| **Build báo 401/403** | Credential `nexus-creds` đúng? Role có quyền repo? | Chạy lại `bootstrap.sh` với `ROTATE_CI_PASSWORD=no` để cập nhật quyền; mật khẩu đổi thì khởi động lại Jenkins |
| **Proxy không tải được (404/502)** | Repository → proxy → trạng thái *Auto-blocked*? | Kiểm tra pod ra được Internet; remote URL; rate limit (Docker Hub); bỏ block bằng *Unblock* |
| **`docker push` lỗi `blob upload unknown`/timeout** | Kích thước layer, timeout ALB | Tăng `idle_timeout` của ALB (GitLab đặt 600 giây cho cả group); kiểm tra dung lượng |
| **`docker login` HTTP/HTTPS** | Thông báo `server gave HTTP response to HTTPS client` | Cấu hình insecure registry (client/containerd) hoặc bật HTTPS |
| **Chậm** | Heap, CPU, log request | Tăng tài nguyên; chuyển H2 → PostgreSQL |
| **Mất dữ liệu** | — | Khôi phục từ snapshot ([6.4](#64-sao-lưu-và-khôi-phục)) |

## 6.7. Lộ trình áp dụng

| Giai đoạn | Việc |
|---|---|
| **Ngay** | Tắt anonymous (hoặc chỉ đọc); cleanup policy + task compact; tăng PVC lên ≥ 100Gi trước khi dùng Docker/OS proxy; khai báo tài khoản Docker Hub cho `docker-proxy` |
| **1–2 tuần** | Task export DB + snapshot EBS hằng ngày; chạy `repos-extra.sh` cho các công nghệ cần dùng; role `read-all` cho lập trình viên |
| **1 tháng** | HTTPS; LDAP; log tập trung; giám sát dung lượng và trạng thái |
| **Trước production** | Blob store S3 (KMS, versioning); PostgreSQL nếu tải lớn; diễn tập khôi phục |
| **Khi cần HA/SSO đầy đủ** | Nexus Pro (`nxrm-ha`), hoặc Harbor cho image + Nexus cho package |
