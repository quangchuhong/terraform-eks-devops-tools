# 9. Quy trình nhánh, phiên bản và phát hành

[← Mục lục Jenkins](README.md)

Áp dụng cho các app dùng Shared Library `ci-lib` ([7](07-shared-library.md)), ví dụ `shopping-cart`.

## 9.1. Mô hình nhánh và môi trường

| Nhánh | Mục đích | Tạo từ / merge vào | Version Maven | `ci-lib` làm gì | Môi trường (khi bật CD) |
|---|---|---|---|---|---|
| `feature/*`, MR | Phát triển, review | Từ `develop` → MR vào `develop` | `x.y.z-SNAPSHOT` | Build, test, Sonar, Quality Gate, Docker build, Trivy. **Không** publish, **không** push | Không deploy |
| **`develop`** | Tích hợp, test version mới hằng ngày | Nhận MR từ `feature/*` và merge ngược từ `release/*`, `hotfix/*` | `1.0.0-SNAPSHOT` | Như trên + `mvn deploy` → `maven-snapshots`, push image `1.0.0-SNAPSHOT-<commit>` | **test** (tự động sync) |
| **`release/x.y`** | Ứng viên phát hành: UAT, staging, kiểm thử bảo mật | Từ `develop` → MR vào `main` khi đạt | `1.0.0-rc.1`, `rc.2`… rồi `1.0.0` | `mvn deploy` → `maven-releases` (không ghi đè), push image `1.0.0-rc.1-<commit>` | **staging** (sync có người duyệt) |
| **`main`** | **Production: chỉ chứa mã đã phát hành** | Chỉ nhận MR từ `release/*` hoặc `hotfix/*` (không push trực tiếp, không merge từ `develop`/`feature/*`) | `x.y.z` (không `-SNAPSHOT`, không `-rc`) | Build lại từ commit đã duyệt, Quality Gate và Trivy **chặn thật** (không waiver), `mvn deploy` → `maven-releases`, push image `x.y.z-<commit>`; tạo tag Git `vX.Y.Z` | **prod** (sync có phê duyệt + change ticket, trong cửa sổ thay đổi) |
| `hotfix/x.y.z` | Sửa gấp lỗi production | Từ `main` (hoặc tag `vX.Y.Z`) → MR vào `main` và `develop` | `x.y.(z+1)` | Như `release/*` | staging → prod |
| `archive/legacy-pipeline` | **Lưu bản code và Jenkinsfile cũ để review** (trước khi chuyển sang `ci-lib`) | Tạo một lần từ `main` (`177d241`), **không thay đổi nữa** | `0.0.1-SNAPSHOT` (như cũ) | Không build (loại khỏi bộ lọc nhánh của Jenkins, [9.4](#94-cấu-hình-gitlab-và-jenkins)) | Không deploy |

`ci-lib` coi `main`, `develop`, `release/*` là nhánh được bảo vệ (publish + push). Với `hotfix/*`, hoặc đặt tên `release/x.y.z-hotfix`, hoặc thêm `hotfix/` vào danh sách nhánh được bảo vệ trong `ciConfig.app` (phát hành MINOR của thư viện).

### Chi tiết chuẩn cho `main` (production)

| Hạng mục | Chuẩn |
|---|---|
| Nguồn thay đổi | Chỉ MR từ `release/*` hoặc `hotfix/*`; tối thiểu **2 người duyệt** (1 tech lead + 1 người ngoài nhóm phát triển, tách bạch nhiệm vụ theo PCI DSS 6.5.x) |
| Bảo vệ nhánh | Push: *No one*; Merge: *Maintainers*; cấm force push; MR bắt buộc pipeline thành công |
| Version | `x.y.z` theo semver; đặt trên `release/*` trước khi merge, không sửa version trên `main` |
| Tag | Sau khi build `main` thành công: tag Git `vX.Y.Z` (protected tag, chỉ Maintainer). Tag là mốc truy vết: commit ↔ jar trong `maven-releases` ↔ image `x.y.z-<commit>` ↔ SBOM ↔ báo cáo Trivy/Sonar |
| Cổng chất lượng | Quality Gate `OK`, Trivy HIGH/CRITICAL **không được waiver** (lỗ hổng chấp nhận được phải ghi qua `.trivyignore`/VEX có Security duyệt), toàn bộ test qua |
| Artifact | Jar `x.y.z` trong `maven-releases` (`allow_once`: không ghi đè); image bất biến (nên dùng ECR `IMMUTABLE` hoặc quy ước không ghi đè tag trên Nexus); SBOM + báo cáo lưu trên S3 (lifecycle 400 ngày) |
| Build once, promote (mục tiêu) | Lý tưởng là **không build lại** trên `main`: dùng đúng image/jar đã test ở staging (`1.0.0-rc.N`), retag thành `1.0.0` khi phát hành. Đây là bước nâng cấp tiếp theo của `ci-lib` (stage *Promote*); hiện tại `main` build lại từ đúng commit đã duyệt |
| Deploy prod | Qua GitOps (Argo CD): MR cập nhật `image.tag` trong repo GitOps nhánh `main`, cần phê duyệt; không ai deploy tay lên prod |
| Rollback | Revert commit GitOps về `image.tag` trước đó (Argo CD sync lại); không rebuild bản cũ |
| Sau phát hành | Merge `main` (hoặc `release/x.y`) ngược về `develop`; tăng `develop` lên `x.(y+1).0-SNAPSHOT` |

## 9.2. Hiện trạng `shopping-cart`

| Nhánh | Trạng thái |
|---|---|
| `develop` | ✅ `ci-lib` (`mavenPipeline`), publish `maven-snapshots`, push image |
| `feature/ci-lib` | ✅ đã merge vào `develop` (có thể xoá) |
| `main` | Vẫn là Jenkinsfile cũ cho đến lần phát hành đầu tiên theo quy trình mới ([9.3](#93-chuyển-main-sang-chuẩn)) |
| `archive/legacy-pipeline` | ✅ bản sao `main` cũ (`177d241`) trên GitHub; cần đẩy lên GitLab và tạo tag `legacy-pipeline-v0` |

Lưu bản cũ lên GitLab và tạo tag (từ thư mục `shopping-cart`):

```bash
git fetch origin archive/legacy-pipeline
git push gitlab origin/archive/legacy-pipeline:refs/heads/archive/legacy-pipeline
git tag -a legacy-pipeline-v0 origin/archive/legacy-pipeline -m "Code and Jenkinsfile of main before the ci-lib migration (kept for review)"
git push origin legacy-pipeline-v0
git push gitlab legacy-pipeline-v0
```

Trên GitLab: Settings → Repository → Protected branches: thêm `archive/*` với Allowed to push = *No one*, Allowed to merge = *No one* (chỉ đọc). Xem bản cũ: `git show legacy-pipeline-v0:Jenkinsfile` hoặc chọn tag trên giao diện GitLab.

## 9.3. Chuyển `main` sang chuẩn

Lần phát hành đầu tiên theo quy trình mới (ví dụ `1.0.0`):

```bash
git checkout develop
git pull gitlab develop
git checkout -b release/1.0
mvn versions:set -DnewVersion=1.0.0-rc.1 -DgenerateBackupPoms=false
git commit -am "Release candidate 1.0.0-rc.1"
git push gitlab release/1.0
```

1. Jenkins build `release/1.0` → jar `1.0.0-rc.1` vào `maven-releases`, image `1.0.0-rc.1-<commit>`. UAT trên staging.
2. Có lỗi: sửa trên `release/1.0`, tăng `rc.2` (`allow_once` không cho build lại cùng version), merge ngược về `develop`.
3. Đạt UAT: `mvn versions:set -DnewVersion=1.0.0`, commit, MR `release/1.0` → `main` (2 người duyệt).
4. Sau merge, Jenkins build `main` bằng `ci-lib`: Jenkinsfile cũ trên `main` được thay bởi `mavenPipeline` (bản cũ vẫn nằm trong `archive/legacy-pipeline` và tag `legacy-pipeline-v0`).
5. Tag `v1.0.0`; merge `main` về `develop`; `develop` lên `1.1.0-SNAPSHOT`.

`shopping-cart` hiện còn waiver Trivy (Spring Boot 1.5): theo chuẩn trên, phải nâng Spring Boot (hoặc ghi nhận ngoại lệ từng CVE có Security duyệt) trước khi merge vào `main`.

## 9.4. Cấu hình GitLab và Jenkins

**GitLab** (project → Settings → Repository):

| Mục | Cấu hình |
|---|---|
| Protected branches | `main`: push *No one*, merge *Maintainers*; `release/*`: push *No one*, merge *Maintainers*; `develop`: push *No one*, merge *Developers + Maintainers*; `archive/*`: push và merge *No one* |
| Protected tags | `v*`, `legacy-*`: chỉ Maintainer tạo |
| Merge request | "Pipelines must succeed" (khi Jenkins báo trạng thái về GitLab), số người duyệt tối thiểu (Premium có approval rules bắt buộc; CE: quy ước + protected branch) |

**Jenkins** (job `shopping-cart` → Configure → Branch Sources → GitLab → Behaviours):

| Behaviour | Giá trị |
|---|---|
| Filter by name (with wildcards) | Include: `main develop release/* hotfix/* feature/*` (không có `archive/*`, nên nhánh lưu trữ không được build) |
| Discover merge requests from origin | Merging the MR with the current target revision |
| Orphaned Item Strategy | Discard old items, giữ 7 ngày |

Webhook GitLab → Jenkins để build ngay khi push: `http://jenkins.jenkins.svc.cluster.local:8080/gitlab-webhook/post` (GitLab Admin → Settings → Network → cho phép request tới mạng nội bộ).

## 9.5. Lưu ý

- **SonarQube Community** chỉ có 1 nhánh phân tích: mọi nhánh ghi vào cùng project. Có thể đặt `sonarProjectKey` riêng cho `release/*`/`main`, hoặc dùng bản Developer (phân tích theo nhánh và MR).
- **Waiver Trivy theo nhánh:** chuẩn trên yêu cầu `release/*` và `main` không dùng waiver. `ci-lib` v1.0.0 chưa phân biệt nhánh cho waiver; dự kiến bổ sung ở v1.0.1.
- **CD đang tạm dừng:** cột "Môi trường" là thiết kế đích khi bật Argo CD (`develop` → test, `release/*` → staging, `main` → prod).
