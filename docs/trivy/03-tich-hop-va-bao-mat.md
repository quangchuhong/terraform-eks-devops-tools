# 3. Tích hợp, chính sách bảo mật và tuân thủ (PCI DSS)

[← Mục lục Trivy](README.md)

## 3.1. Bản đồ tích hợp

| Tích hợp | Hiện trạng | Cách làm |
|---|---|---|
| **Jenkins** (`shopping-cart`) | ✅ | Container `trivy` trong pod build, quét `image.tar`, lưu `trivy-report.json/.txt` làm artifact (S3), cổng `TRIVY_EXIT_CODE` |
| **Shared Library `ci-lib`** | ✅ (mã nguồn) | `ciImage.scan`: cổng HIGH/CRITICAL luôn bật, waiver có hạn, `.trivyignore` |
| **GitLab CI** | Có thể dùng | Job `image: aquasec/trivy:0.68.2`, `trivy image --server http://trivy.trivy.svc.cluster.local:9090 ...`; GitLab đọc báo cáo dạng `container_scanning` nếu dùng template GitLab ([7.1](07-cach-dung-theo-loai-quet.md#71-image)) |
| **Nexus / ECR** | Gián tiếp | Quét trước khi push lên Nexus. Với ECR: thêm ECR scan (Basic/Inspector) để theo dõi CVE mới sau khi push |
| **Kubernetes** | ⏸ | Trivy Operator quét định kỳ workload đang chạy ([6.4](06-van-hanh-va-tu-dong-hoa.md#64-quét-liên-tục-trong-cụm-trivy-operator)) |
| **SonarQube** | Bổ trợ | SonarQube: lỗi trong mã do mình viết; Trivy: lỗ hổng thành phần bên thứ ba |
| **Dependency-Track** | ⏸ Đề xuất | Upload SBOM CycloneDX của mỗi build → danh mục + cảnh báo CVE mới ([6.3](06-van-hanh-va-tu-dong-hoa.md#63-sbom-và-dependency-track)) |
| **DefectDojo** | Tuỳ chọn | Gom kết quả Trivy, SonarQube, ZAP... vào một nơi quản lý lỗ hổng |

## 3.2. Chính sách quét đề xuất

| Điểm kiểm tra | Lệnh | Chặn khi |
|---|---|---|
| MR / commit (repo) | `trivy fs --scanners vuln,secret,misconfig .` | Secret bất kỳ; misconfig HIGH/CRITICAL; lỗ hổng CRITICAL có bản sửa |
| Build image | `trivy image --server ... --input image.tar` | HIGH/CRITICAL có bản sửa (`--ignore-unfixed`) |
| Trước khi deploy prod | Kiểm tra báo cáo/SBOM của đúng image digest | Có CRITICAL chưa có ngoại lệ hợp lệ |
| Đang chạy | Trivy Operator / ECR Enhanced scanning | Cảnh báo (không chặn), tạo ticket theo SLA |

SLA xử lý gợi ý (theo mức độ): CRITICAL 7 ngày, HIGH 30 ngày, MEDIUM 90 ngày.

### Quản lý ngoại lệ

| Cách | Khi dùng | Kiểm soát |
|---|---|---|
| `.trivyignore` trong repo app | CVE không ảnh hưởng (không dùng hàm lỗi, không khai thác được trong ngữ cảnh) | Mỗi dòng có lý do, người duyệt, ngày xem lại; `CODEOWNERS` yêu cầu Security duyệt file này |
| VEX (`--vex`) | Muốn ghi nhận chuẩn, dùng lại được với công cụ khác | Như trên |
| Waiver có hạn (`trivyWaiverUntil` của `ci-lib`) | Cả image chưa sửa được ngay (ví dụ Spring Boot 1.5 cần nâng cấp lớn) | Có ngày hết hạn; hết hạn build tự FAILED |

Ví dụ `.trivyignore`:

```
# CVE-2024-XXXXX: chỉ ảnh hưởng chế độ XML external entity, ứng dụng không parse XML từ người dùng.
# Duyệt: security-team 2026-11-01. Xem lại: 2027-02-01
CVE-2024-XXXXX
```

## 3.3. Lộ trình hoàn thiện

| # | Việc | Ghi chú |
|---|---|---|
| 1 | Bật cổng chặn cho mọi app (`--exit-code 1 --ignore-unfixed --severity HIGH,CRITICAL`) | `shopping-cart` dùng waiver có hạn cho tới khi nâng Spring Boot |
| 2 | Sinh SBOM CycloneDX cho mọi image, lưu làm artifact (S3) | Đáp ứng PCI DSS 6.3.2 |
| 3 | `serverToken` cho Trivy server (Secret), client truyền `--token` | Chặn truy cập trái phép trong cụm |
| 4 | Mirror Trivy DB + Java DB nội bộ, cache Java DB | Nhanh hơn, không phụ thuộc ghcr.io, chạy được khi mất Internet |
| 5 | Quét repo (`trivy fs`: secret, misconfig) ở MR | Phát hiện sớm |
| 6 | Quét IaC hạ tầng (`trivy config` cho repo Terraform, Helm values) | Phát hiện bucket public, SG mở, pod privileged... |
| 7 | Quét liên tục image đang chạy (Trivy Operator hoặc ECR/Inspector) | CVE mới công bố sau khi deploy |
| 8 | Dependency-Track (hoặc Black Duck) làm danh mục và dashboard | [4.4](04-so-sanh-trivy-blackduck.md#44-khi-nào-dùng-công-cụ-nào) |
| 9 | Ghim image Trivy theo digest, kiểm tra chữ ký (cosign) | Giảm rủi ro chuỗi cung ứng của chính công cụ quét |
| 10 | NetworkPolicy: chỉ pod build gọi được Trivy server | |

## 3.4. Đối chiếu PCI DSS v4.0.1

| Yêu cầu | Nội dung | Trivy đáp ứng | Hiện trạng |
|---|---|---|---|
| **6.3.1** | Xác định lỗ hổng bảo mật từ nguồn uy tín, xếp hạng rủi ro | DB tổng hợp NVD, GHSA, distro; mức độ CVSS/distro | ✅ |
| **6.3.2** | Kiểm kê phần mềm tự phát triển và thành phần bên thứ ba | SBOM CycloneDX/SPDX | ⚠️ Chưa sinh SBOM |
| **6.3.3** | Cài bản vá bảo mật (critical trong 1 tháng) | Cổng chặn + báo cáo để theo dõi | ⚠️ Cổng đang tắt cho `shopping-cart` |
| **6.4.x / 6.5.x** | Quy trình thay đổi, môi trường an toàn | Quét trong pipeline trước khi phát hành | ✅ |
| **11.3.1** | Quét lỗ hổng nội bộ định kỳ (3 tháng/lần), xử lý HIGH/CRITICAL | `trivy k8s`, Trivy Operator, `trivy vm`/AMI | ⚠️ Chưa quét định kỳ hệ thống đang chạy |
| **2.2** | Cấu hình an toàn cho thành phần hệ thống | `trivy config` (CIS cho Kubernetes, Dockerfile, Terraform) | ⚠️ Chưa dùng |
| **3.x / 8.x** | Không lưu thông tin xác thực ở dạng rõ | `--scanners secret` | ⚠️ Chưa dùng |

Lưu ý: PCI DSS 11.3.2 (quét bên ngoài) yêu cầu nhà cung cấp quét được chứng nhận (ASV), Trivy không thay thế được phần này.
