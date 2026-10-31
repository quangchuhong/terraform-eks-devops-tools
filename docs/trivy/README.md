# Trivy: tài liệu kỹ thuật (và so sánh với Black Duck)

Trivy là công cụ quét bảo mật mã nguồn mở (Aqua Security, Apache 2.0) của nền tảng DevOps trên EKS. Trong pipeline, Trivy quét image container trước khi đẩy lên Nexus và chặn build khi có lỗ hổng mức HIGH/CRITICAL.

| Hạng mục | Giá trị |
|---|---|
| Phiên bản | Trivy **0.68.2**, chart `trivy` 0.20.1 |
| Chế độ | **Client/server**: server trong cụm giữ cơ sở dữ liệu lỗ hổng; client chạy trong pod build |
| Endpoint | `http://trivy.trivy.svc.cluster.local:9090` (chỉ trong cụm, không có Ingress) |
| Namespace | `trivy` |
| Cài đặt | `helm upgrade --install trivy ./helm-install/trivy-scanner/trivy -n trivy --create-namespace` |
| Dùng trong | Jenkinsfile `shopping-cart` (stage *Trivy Scan Image*), Shared Library `ci-lib` (`ciImage.scan`) |

## Nội dung

1. [Kiến trúc và các tuỳ chọn cấu hình](01-kien-truc-va-cau-hinh.md): client/server, cơ sở dữ liệu lỗ hổng (Trivy DB, Java DB), các loại quét, ý nghĩa cấu hình.
2. [Sizing theo mức tải](02-sizing.md): tài nguyên server và client, cache DB, ổ tạm của pod build, cho tải thấp/vừa/enterprise.
3. [Tích hợp, bảo mật và tuân thủ PCI DSS](03-tich-hop-va-bao-mat.md): Jenkins, GitLab CI, Nexus/ECR, Kubernetes, Dependency-Track; chính sách chặn và ngoại lệ; đối chiếu PCI DSS v4.0.1.
4. [So sánh Trivy và Black Duck](04-so-sanh-trivy-blackduck.md): khả năng phát hiện, nguồn dữ liệu lỗ hổng, license, SBOM, triển khai, chi phí, khi nào dùng công cụ nào; kèm Grype, Snyk, JFrog Xray, Amazon Inspector.
5. [Hướng dẫn cấu hình đã triển khai](05-huong-dan-trien-khai.md): cài server, cách pipeline gọi Trivy, kiểm tra, nâng cấp, sự cố đã gặp.
6. [Vận hành và tự động hoá](06-van-hanh-va-tu-dong-hoa.md): cập nhật DB, mirror DB nội bộ, quản lý ngoại lệ, SBOM và Dependency-Track, Trivy Operator, runbook.
7. [Cách dùng theo loại quét](07-cach-dung-theo-loai-quet.md): image, filesystem/repo, SBOM, IaC (Terraform, Kubernetes, Dockerfile), secret, license, cụm Kubernetes.

## Tóm tắt nhanh

- **Đang tốt:** quét mọi image trước khi push; báo cáo JSON + bảng lưu làm artifact (trên S3); server giữ DB tập trung nên client không phải tải Trivy DB mỗi lần; server chạy non-root, root filesystem chỉ đọc; không mở ra Internet.
- **Cần làm:** bật cổng chặn (`TRIVY_EXIT_CODE='1'` hoặc waiver có hạn của `ci-lib`); sinh và lưu **SBOM**; cache/mirror Java DB (client đang tải khoảng 3–4 GB mỗi build); đặt `serverToken`; quét định kỳ image đang chạy (Trivy Operator hoặc ECR/Inspector); quét IaC (Terraform, Helm, Dockerfile). Chi tiết ở [phần 3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hoàn-thiện).
