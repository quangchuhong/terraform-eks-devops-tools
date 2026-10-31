# 5. Hướng dẫn cấu hình đã triển khai

[← Mục lục Trivy](README.md)

## 5.1. Cài Trivy server

```bash
helm upgrade --install trivy ./helm-install/trivy-scanner/trivy -n trivy --create-namespace
kubectl -n trivy get pods,pvc,svc
kubectl -n trivy logs statefulset/trivy --tail=20
```

Mong đợi: pod `trivy-0` `1/1 Running`, PVC 5Gi `Bound`, Service `trivy` cổng 9090. Lần đầu server tải Trivy DB (vài trăm MB) trước khi sẵn sàng.

Kiểm tra từ trong cụm:

```bash
kubectl run trivy-check -n trivy --rm -it --restart=Never --image=aquasec/trivy:0.68.2 -- \
  image --server http://trivy.trivy.svc.cluster.local:9090 --scanners vuln --severity CRITICAL alpine:3.20
```

Không bật Ingress: server chưa có `serverToken`, mở ra ALB thì ai cũng gọi được.

## 5.2. Dùng trong pipeline

Jenkinsfile `shopping-cart`:

1. `podTemplate` có container `trivy` (`aquasec/trivy:0.68.2`, cùng phiên bản server).
2. Stage *Docker Build*: `docker build` rồi `docker save -o image-<app>-<tag>.tar`.
3. Stage *Trivy Scan Image*: quét file tar (workspace dùng chung), lưu báo cáo, cổng HIGH/CRITICAL với `TRIVY_EXIT_CODE`. Lệnh chi tiết ở [1.3](01-kien-truc-va-cau-hinh.md#13-cấu-hình-client-trong-pipeline).
4. `archiveArtifacts 'trivy-report.json,trivy-report.txt'`: lưu vào bucket S3 `jenkins-609320954321-artifacts`, xem trên trang build.
5. Stage *Push Image* chỉ chạy sau khi Trivy qua.

Kết quả thực tế: build `main` #6 có `trivy-report.json` (1,3MB) và `trivy-report.txt` (300KB) trên S3; Spring Boot 1.5 có nhiều HIGH/CRITICAL nên cổng đang để `TRIVY_EXIT_CODE='0'`.

Đọc nhanh báo cáo JSON:

```bash
jq -r '.Results[] | .Target as $t | (.Vulnerabilities // [])[] | select(.Severity=="CRITICAL") | "\($t)\t\(.PkgName)\t\(.InstalledVersion)\t\(.VulnerabilityID)\t\(.FixedVersion // "-")"' trivy-report.json
jq '[.Results[].Vulnerabilities // [] | .[]] | group_by(.Severity) | map({(.[0].Severity): length}) | add' trivy-report.json
```

## 5.3. Nâng cấp

1. Đổi `version`/`appVersion` của chart (tải chart mới vào `helm-install/trivy-scanner/`) hoặc `image.tag` trong values.
2. Đổi image client trong mọi `podTemplate` (Jenkinsfile, `ci-lib` `ciConfig.images.trivy`) **cùng phiên bản**.
3. `helm upgrade trivy ./helm-install/trivy-scanner/trivy -n trivy`, chạy lại lệnh kiểm tra ở 5.1, chạy một build.

Đọc release notes: Trivy thỉnh thoảng đổi tên tuỳ chọn hoặc định dạng báo cáo; client và server lệch phiên bản lớn có thể không tương thích.

## 5.4. Sự cố đã gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Pod build **Evicted** (`The node was low on resource: ephemeral-storage`) ở stage Trivy | Ổ gốc node 20 GiB: image tar + layer giải nén + Java DB + dind | Ổ gốc node 100 GiB (`node_disk_size`), node group CI riêng; giới hạn `--scanners vuln` |
| Stage Trivy chậm vài phút ở lần đầu mỗi build | Client tải Java DB (khoảng 3–4 GB giải nén) vì pod build tạm thời không có cache | Mirror/cache Java DB ([6.2](06-van-hanh-va-tu-dong-hoa.md#62-mirror-db-nội-bộ)) |
| Build không bị chặn dù có CRITICAL | `TRIVY_EXIT_CODE='0'` (chủ ý cho Spring Boot 1.5) | Nâng Spring Boot rồi đặt `'1'`; hoặc chuyển sang `ci-lib` với waiver có hạn |
| Báo cáo có nhiều lỗ hổng "won't fix" của gói OS | Distro chưa/không phát hành bản sửa | `--ignore-unfixed` cho cổng chặn; dùng image nền nhỏ (distroless, `-jre-alpine`) |
