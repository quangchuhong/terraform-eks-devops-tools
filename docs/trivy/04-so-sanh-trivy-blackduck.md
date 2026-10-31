# 4. So sánh Trivy và Black Duck

[← Mục lục Trivy](README.md)

## 4.1. Hai công cụ giải quyết bài toán khác nhau

| | Trivy | Black Duck |
|---|---|---|
| Nhà phát triển | Aqua Security, mã nguồn mở Apache 2.0 | Black Duck Software (tách từ Synopsys năm 2024), thương mại |
| Bản chất | **Máy quét** (CLI/server), chạy nhanh trong pipeline, cho kết quả ngay | **Nền tảng SCA** (Software Composition Analysis): quản lý danh mục thành phần mã nguồn mở của toàn bộ ứng dụng, chính sách, license, báo cáo |
| Câu hỏi trả lời | "Image/artifact này có lỗ hổng đã biết hoặc cấu hình sai không? Có cho đi tiếp không?" | "Tổ chức đang dùng những thành phần mã nguồn mở nào, ở đâu, license gì, rủi ro gì, ai chịu trách nhiệm, đã xử lý chưa?" |
| Lưu trữ kết quả | Không có server lưu lịch sử (chỉ file báo cáo) | Có: Bill of Materials (BOM) cho từng project/version, lịch sử, trạng thái xử lý, báo cáo |
| Đối tượng chính | Image container, file system, repo, IaC, cụm Kubernetes | Mã nguồn, binary, image container của ứng dụng |

Hai công cụ **không thay thế hoàn toàn cho nhau**; nhiều ngân hàng dùng cả hai: Trivy (hoặc tương đương) làm cổng chặn nhanh trong CI, Black Duck làm hệ thống quản trị rủi ro mã nguồn mở và license.

## 4.2. So sánh chi tiết

### Khả năng phát hiện

| Tiêu chí | Trivy | Black Duck |
|---|---|---|
| Gói OS trong image (deb, rpm, apk) | ✅ Mạnh, dùng dữ liệu của distro | ✅ (quét container) |
| Thư viện qua package manager (Maven, npm, pip, NuGet, Go, Cargo...) | ✅ Đọc file khoá/manifest và metadata trong image | ✅ **Detect** phân tích package manager, kể cả phụ thuộc bắc cầu khi chạy build |
| Jar không có metadata, thư viện "nhúng" | ⚠️ Nhận diện jar bằng Java DB (checksum) | ✅ **Signature scanning** (so dấu vân tay file/thư mục) |
| **Snippet** (đoạn mã copy từ dự án mã nguồn mở vào mã của mình) | ❌ | ✅ **Snippet scanning** |
| Binary đã biên dịch (firmware, .so/.dll, ứng dụng không có mã nguồn) | ⚠️ Hạn chế (chủ yếu theo metadata) | ✅ **Binary Analysis (BDBA)** |
| C/C++ (không có package manager chuẩn) | ⚠️ Hạn chế (Conan lock file) | ✅ Signature/snippet/binary scan phù hợp C/C++ |
| Cấu hình sai IaC (Terraform, Kubernetes, Dockerfile, Helm) | ✅ | ❌ (không phải phạm vi) |
| Secret trong mã/image | ✅ | ❌ |
| Quét cụm Kubernetes đang chạy | ✅ `trivy k8s`, Trivy Operator | ❌ |
| SAST (lỗi trong mã do mình viết) | ❌ (dùng SonarQube) | ❌ (sản phẩm khác: Coverity/Polaris) |

### Dữ liệu lỗ hổng và license

| Tiêu chí | Trivy | Black Duck |
|---|---|---|
| Nguồn lỗ hổng | Công khai: NVD, GitHub Advisory, bản tin distro, OSV... (cập nhật vài giờ một lần) | NVD + **BDSA** (Black Duck Security Advisories): nghiên cứu riêng, thường có trước hoặc chi tiết hơn NVD (phiên bản bị ảnh hưởng, cách khắc phục, mức khai thác) |
| Độ chính xác | Tốt với gói OS (theo distro); thư viện phụ thuộc metadata | Tốt, có đội ngũ chuẩn hoá dữ liệu (KnowledgeBase) |
| License | ⚠️ Phát hiện license từ metadata (`--scanners license`), phân loại cơ bản | ✅ **Mạnh**: nhận diện license kể cả ở mức file/snippet, nghĩa vụ license, xung đột license, báo cáo pháp lý (attribution/notice) |
| Rủi ro vận hành (thành phần cũ, không còn bảo trì) | ❌ | ✅ (operational risk: phiên bản cũ, hoạt động của cộng đồng) |
| VEX | ✅ Đọc VEX để loại CVE không ảnh hưởng | ✅ Quản lý trạng thái khắc phục, phát hành VEX |

### Chính sách, quy trình, báo cáo

| Tiêu chí | Trivy | Black Duck |
|---|---|---|
| Cổng chặn trong pipeline | ✅ `--exit-code`, `--severity`, `--ignore-unfixed`, Rego | ✅ Policy (lỗ hổng, license, rủi ro vận hành) → Detect trả lỗi khi vi phạm |
| Ngoại lệ | `.trivyignore`, VEX, Rego (quản lý bằng Git, review qua MR) | Trên giao diện: đánh dấu đã xem xét, ignore, có lý do, người duyệt, thời hạn; có audit |
| Danh mục toàn tổ chức, dashboard | ❌ (cần thêm Dependency-Track, DefectDojo, hoặc Aqua thương mại) | ✅ |
| Cảnh báo khi có CVE mới cho phần mềm đã phát hành | ❌ (phải quét lại hoặc dùng Dependency-Track/Trivy Operator) | ✅ Theo dõi liên tục BOM đã lưu |
| SBOM | ✅ Sinh CycloneDX/SPDX, quét SBOM | ✅ Sinh và nhập SBOM (SPDX, CycloneDX), quản lý theo version |
| Báo cáo cho kiểm toán, pháp chế | Tự tổng hợp từ JSON | ✅ Có sẵn (vulnerability, license, notice file) |
| Tích hợp | CLI, mọi CI, IDE (VS Code), Kubernetes | Jenkins plugin, GitLab, Azure DevOps, IDE (Code Sight), Jira, API |

### Triển khai và chi phí

| Tiêu chí | Trivy | Black Duck |
|---|---|---|
| Triển khai | 1 binary/image; server tuỳ chọn (1 pod nhỏ) | SaaS (Black Duck SCA SaaS / Polaris) hoặc **tự host trên Kubernetes** (Helm chart, nhiều thành phần: web app, scan, job runner, registration, PostgreSQL...) |
| Tài nguyên tự host | Server: 200m CPU / 512Mi; client: CPU + ổ tạm cho image và Java DB | Lớn: hàng chục vCPU và hàng chục GB RAM tuỳ gói sizing (số lần quét/giờ), PostgreSQL riêng (khuyến nghị RDS) |
| Mạng | Tải DB từ ghcr.io (hoặc mirror nội bộ) | Kết nối tới Black Duck KnowledgeBase (hoặc gói dữ liệu offline cho môi trường cô lập, tuỳ hợp đồng) |
| Chi phí | Miễn phí (hỗ trợ thương mại qua Aqua) | License theo năm (thường theo số ứng dụng/dòng mã/người đóng góp, kèm module binary/snippet), cao |
| Thời gian quét | Giây đến vài phút | Vài phút đến lâu hơn (signature/snippet/binary scan); thường chạy bất đồng bộ |
| Hỗ trợ | Cộng đồng; Aqua cho bản thương mại | Hỗ trợ thương mại, SLA |

## 4.3. Ưu và nhược điểm

**Trivy**

| Ưu điểm | Nhược điểm |
|---|---|
| Miễn phí, mã nguồn mở, phổ biến, cập nhật nhanh | Không có nơi lưu lịch sử, dashboard, quy trình xử lý (cần công cụ bổ sung) |
| Nhanh, nhẹ, phù hợp làm cổng chặn trong mọi pipeline | Dữ liệu lỗ hổng chỉ từ nguồn công khai |
| Một công cụ quét nhiều loại: image, thư viện, IaC, secret, cụm Kubernetes, SBOM | Không có snippet scan, binary analysis sâu; license cơ bản |
| Dữ liệu distro cho gói OS, ít báo nhầm | Ngoại lệ quản lý bằng file, không có giao diện duyệt/audit sẵn |
| Chạy offline được (mirror DB) | Tự chịu trách nhiệm vận hành, không có SLA |

**Black Duck**

| Ưu điểm | Nhược điểm |
|---|---|
| Quản trị mã nguồn mở toàn diện: BOM, chính sách, license, rủi ro vận hành | Chi phí license cao |
| BDSA: dữ liệu lỗ hổng riêng, chi tiết, thường sớm hơn NVD | Tự host nặng (nhiều thành phần, PostgreSQL, tài nguyên lớn) hoặc phải chấp nhận SaaS |
| Signature, snippet, binary scan: tìm được mã nguồn mở không khai báo (C/C++, mã copy, phần mềm mua ngoài) | Quét chậm hơn, cần cấu hình Detect cho từng loại build |
| Báo cáo cho kiểm toán và pháp chế, workflow duyệt ngoại lệ có audit | Không quét IaC, secret, cụm Kubernetes |
| Hỗ trợ thương mại, phù hợp yêu cầu nhà cung cấp của ngân hàng | Phụ thuộc nhà cung cấp |

## 4.4. Khi nào dùng công cụ nào

| Tình huống | Gợi ý |
|---|---|
| Cổng chặn lỗ hổng trong CI cho image và thư viện | **Trivy** (đang dùng) |
| Cần danh mục thành phần, theo dõi CVE mới cho phần mềm đã phát hành, nhưng ngân sách hạn chế | **Trivy (sinh SBOM) + OWASP Dependency-Track** (miễn phí, có dashboard, chính sách, cảnh báo) |
| Ngân hàng cần quản trị license (phần mềm phân phối cho khách hàng, app mobile), báo cáo pháp chế | **Black Duck** (hoặc sản phẩm SCA thương mại tương đương) |
| Nhiều mã C/C++, firmware, phần mềm mua ngoài không có mã nguồn | **Black Duck** (signature/snippet/BDBA) |
| Kiểm toán yêu cầu công cụ có hỗ trợ thương mại, workflow ngoại lệ có audit | **Black Duck**, giữ Trivy cho IaC/secret/Kubernetes |

### Mô hình đề xuất cho hệ thống này

```
Commit/MR ──► SonarQube (SAST, chất lượng)
          ──► Trivy fs/config: thư viện, secret, IaC (nhanh, chặn sớm)
Build image ─► Trivy image: cổng HIGH/CRITICAL (--ignore-unfixed), sinh SBOM CycloneDX
            ─► SBOM ──► Dependency-Track (giai đoạn 1, miễn phí) hoặc Black Duck (giai đoạn 2, khi cần license/BDSA)
Đang chạy ──► Trivy Operator / ECR Enhanced scanning: phát hiện CVE mới trên image đang dùng
```

- Giai đoạn 1 (ngay, miễn phí): Trivy làm cổng chặn + SBOM + Dependency-Track làm danh mục và cảnh báo.
- Giai đoạn 2 (khi có yêu cầu license/pháp chế, nhiều C/C++ hoặc phần mềm bên thứ ba): bổ sung Black Duck; Detect chạy trong pipeline (Jenkins plugin) song song với Trivy. Trivy vẫn giữ phần IaC, secret, Kubernetes mà Black Duck không làm.

Tích hợp Black Duck vào Jenkins (tham khảo, khi có license):

```bash
bash <(curl -s -L https://detect.blackduck.com/detect10.sh) \
  --blackduck.url=https://blackduck.example.bank \
  --blackduck.api.token="$BLACKDUCK_TOKEN" \
  --detect.project.name=shopping-cart \
  --detect.project.version.name="$POM_VERSION" \
  --detect.tools=DETECTOR,SIGNATURE_SCAN \
  --detect.policy.check.fail.on.severities=BLOCKER,CRITICAL
```

Token lấy từ Jenkins credential (Kubernetes Secret), không ghi trong Jenkinsfile. Tên script và tham số theo phiên bản Detect đang dùng (kiểm tra tài liệu Black Duck).

## 4.5. Các công cụ khác cùng loại (tham khảo)

| Công cụ | Loại | Điểm chính |
|---|---|---|
| Grype + Syft (Anchore) | Mã nguồn mở | Syft sinh SBOM, Grype quét lỗ hổng; tương tự phần `vuln` của Trivy |
| Snyk | Thương mại (có bản miễn phí giới hạn) | SCA + container + IaC + SAST, trải nghiệm lập trình viên tốt, SaaS |
| JFrog Xray | Thương mại | Gắn với Artifactory, quét artifact trong kho, chặn tải |
| Amazon Inspector (ECR Enhanced scanning) | Dịch vụ AWS | Quét image trên ECR liên tục, Lambda, EC2; tính phí theo lần quét |
| Aqua Platform | Thương mại (cùng hãng Trivy) | Dashboard, chính sách, runtime protection, dựa trên lõi Trivy |
| Mend (WhiteSource), Sonatype Lifecycle | Thương mại | SCA tương tự Black Duck; Sonatype tích hợp với Nexus (Firewall chặn package nguy hiểm khi proxy) |
