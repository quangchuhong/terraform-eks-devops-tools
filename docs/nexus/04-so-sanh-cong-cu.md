# 4. So sánh Nexus với các kho artifact khác

[← Mục lục Nexus](README.md)

## 4.1. Bảng so sánh

| Tiêu chí | Nexus CE (đang dùng) | Nexus Pro | JFrog Artifactory (Pro/Enterprise) | Harbor | GitLab Package/Container Registry | AWS CodeArtifact + ECR | GCP Artifact Registry | Azure Artifacts + ACR |
|---|---|---|---|---|---|---|---|---|
| Tự host | Có, miễn phí (có giới hạn mức dùng) | Có, license | Có (hoặc SaaS) | Có, miễn phí (CNCF) | Có (đi kèm GitLab) | Không (dịch vụ AWS) | Không (dịch vụ GCP) | Không (dịch vụ Azure) |
| Định dạng | Rất nhiều: Maven, npm, PyPI, NuGet, Docker, Helm, apt, yum, raw, Conan, Go, R, Cargo... | Như CE + một số định dạng/tính năng | Nhiều nhất (hơn 30 loại, có Terraform, vcpkg, Alpine...) | Chỉ OCI (image, Helm chart OCI, artifact OCI) | Maven, npm, PyPI, NuGet, Conan, Go, Helm, generic, container | CodeArtifact: Maven, npm, PyPI, NuGet, Swift, Ruby, generic; ECR: OCI | Maven, npm, Python, Docker/OCI, apt, yum, Go, generic, Kubeflow | Artifacts: Maven, npm, NuGet, Python, Universal; ACR: OCI |
| Proxy kho công khai | Có, mọi định dạng | Có | Có (remote) | Có (proxy cache cho registry) | Hạn chế (dependency proxy cho container, Maven/npm/PyPI một phần) | Có (upstream: Maven Central, npm, PyPI, NuGet); ECR pull-through cache | Có (remote repository) | Có (upstream sources); ACR cache |
| HA | Không | Có (nhiều node, PostgreSQL, blob chung) | Có | Có (nhiều replica, DB ngoài) | Theo GitLab | Có sẵn (dịch vụ quản lý) | Có sẵn | Có sẵn |
| Quét lỗ hổng | Không tích hợp (dùng Trivy ở pipeline) | Kèm Sonatype Lifecycle/Firewall (trả thêm) | JFrog Xray (trả thêm) | Có sẵn (Trivy tích hợp) | Container Scanning (Ultimate có dashboard) | ECR scanning (Inspector) | Artifact Analysis | Microsoft Defender for Containers |
| Ký và chính sách image | Không | Không | Có (Xray, signing) | Có (Cosign/Notation, chặn image chưa ký, chặn theo mức lỗ hổng) | Hạn chế | ECR + signing qua AWS Signer | Binary Authorization | Notation |
| SSO | LDAP | LDAP, SAML, user token | LDAP, SAML, OIDC, SCIM | LDAP, OIDC | Theo GitLab | IAM | IAM | Entra ID |
| Chi phí | Hạ tầng | License theo năm | License cao | Hạ tầng | Theo GitLab | Theo dung lượng + request | Theo dung lượng + network | Theo dung lượng |

## 4.2. Ưu và nhược điểm của Nexus trong hệ thống này

**Ưu điểm:**

- Một công cụ cho gần như mọi định dạng: Maven, Python, Node.js, Docker, gói Linux, NuGet/Chocolatey, Conan, file raw. Phù hợp ngân hàng có nhiều công nghệ (Java, .NET, C/C++, Python).
- Proxy có cache cho kho công khai: build nhanh hơn, ít phụ thuộc Internet, có một điểm kiểm soát nguồn thư viện (chặn, kiểm kê).
- Tự host trên EKS, dữ liệu nằm trong account; không phụ thuộc cloud cụ thể (dùng được cho cả hệ thống on-premise, AWS, GCP, Azure).
- CE miễn phí, đủ cho quy mô hiện tại.

**Nhược điểm:**

- CE không có HA, không SAML, không user token, có giới hạn mức dùng từ 3.77.
- Không có quét lỗ hổng, ký image, chính sách chặn image như Harbor hay Artifactory + Xray; phải bù bằng Trivy và quy trình pipeline.
- Docker trên Nexus cần cổng/hostname riêng cho từng repo (connector).
- Một pod + một volume: dung lượng và sao lưu phải tự lo.

## 4.3. Khi nào nên cân nhắc lựa chọn khác

| Tình huống | Gợi ý |
|---|---|
| Cần HA, SAML/SSO, user token, audit | **Nexus Pro** (giữ nguyên cách dùng, có chart `nxrm-ha` sẵn trong repo) |
| Cần registry container với quét, ký, chính sách chặn image cho Kubernetes | **Harbor** cho image (Nexus vẫn giữ Maven/npm/PyPI/OS packages) |
| Tổ chức lớn, nhiều site, cần một nền tảng artifact kèm quét bảo mật | JFrog Artifactory + Xray |
| Hệ thống chỉ chạy trên một cloud và muốn dịch vụ quản lý | AWS CodeArtifact + ECR (pull-through cache), GCP Artifact Registry, Azure Artifacts + ACR; Nexus có thể làm proxy phía trước để thống nhất cách dùng ([phần 7](07-cau-hinh-theo-cong-nghe.md)) |
| Chỉ cần chỗ lưu package cho vài project trên GitLab | GitLab Package Registry |

## 4.4. Lưu Docker image: Nexus so với Amazon ECR

### Khác nhau về bản chất

| | Nexus (docker-hosted, đang dùng) | Amazon ECR (private) |
|---|---|---|
| Là gì | Ứng dụng tự chạy trên EKS (1 pod + PVC EBS 20Gi) | Dịch vụ AWS quản lý (không có máy chủ để vận hành) |
| Ai vận hành | Team mình: nâng cấp, dung lượng, sao lưu, HA | AWS (SLA 99,9%), mình chỉ cấu hình repo và quyền |
| Đơn vị tổ chức | Một repo `docker-hosted` chứa mọi image, phân theo đường dẫn `<team>/<app>` | Mỗi image một **repository** (`dev-backend/shopping-cart`); tạo trước bằng Terraform hoặc tự tạo khi push (repository creation template) |
| Xác thực | User/mật khẩu Nexus (`docker login`) | **IAM**: node EKS pull bằng IAM role của node, pod CI push bằng IRSA; ngoài AWS dùng `aws ecr get-login-password` (token 12 giờ) |
| Giao thức | Hiện là **HTTP** (phải cấu hình insecure registry cho Docker/containerd) | Luôn **HTTPS** |
| Định dạng khác | Cùng chỗ với Maven, npm, PyPI, NuGet, apt, yum... | Chỉ OCI (image, Helm chart OCI, artifact OCI) |
| Proxy kho công khai | Docker Hub, ghcr, quay, registry.k8s.io, mcr, gcr... trong một `docker-group` | **Pull-through cache**: Docker Hub, ghcr.io, quay.io, registry.k8s.io, ECR Public, Azure CR, GitLab CR (Docker Hub/ghcr cần credential trong Secrets Manager) |

### Tính năng

| Tính năng | Nexus CE | ECR |
|---|---|---|
| Quét lỗ hổng | Không (Trivy ở pipeline) | Basic scan (miễn phí) hoặc **Enhanced** với Amazon Inspector (quét liên tục cả khi có CVE mới) |
| Tag bất biến | Không theo tag (chỉ write policy cả repo) | `IMMUTABLE` theo từng repository (không ghi đè tag đã push) |
| Dọn image cũ | Cleanup policy + task compact | **Lifecycle policy** (giữ N image, xoá untagged sau X ngày), tự chạy |
| Mã hoá | EBS mã hoá | AES-256 mặc định hoặc **KMS CMK** |
| Nhân bản | Không (CE) | Replication cross-region / cross-account (DR, nhiều môi trường) |
| Ký image | Không | Ký bằng AWS Signer/Notation, kiểm tra khi deploy (Kyverno/Gatekeeper) |
| Audit | Log ứng dụng | **CloudTrail** ghi mọi push/pull/xoá (phục vụ PCI DSS 10) |
| HA | Không (1 pod, 1 AZ) | Có sẵn, đa AZ |
| Giới hạn | Dung lượng PVC, giới hạn mức dùng CE | Quota mềm (số repo, request/giây), tăng được |

### Chi phí (tham khảo, kiểm tra bảng giá AWS theo region)

| Khoản | Nexus | ECR |
|---|---|---|
| Lưu trữ | EBS gp3 (khoảng 0,08–0,1 USD/GB-tháng), phải cấp dư cho cả dung lượng chưa dùng | Khoảng 0,10 USD/GB-tháng, chỉ trả phần thực dùng |
| Tính toán | Chia sẻ node (1–2 CPU, 4Gi) chạy 24/7 | Không |
| Truyền dữ liệu | Trong VPC; qua ALB thì tính phí ALB | Pull từ EKS **cùng region miễn phí**; ra Internet/khác region tính phí; node ở subnet private cần VPC endpoint (`ecr.api`, `ecr.dkr`, `s3`) hoặc NAT |
| Vận hành | Công sức của team (nâng cấp, dung lượng, sao lưu) | Gần như không |

Với vài trăm GB image, chi phí lưu trữ hai bên tương đương; khác biệt lớn nằm ở công vận hành và tính năng bảo mật.

### Ưu và nhược điểm

**Nexus**

| Ưu điểm | Nhược điểm |
|---|---|
| Một nơi cho mọi loại artifact; một cách cấu hình client | Tự vận hành: 1 pod, PVC 20Gi, chưa có sao lưu, là điểm lỗi đơn |
| Không phụ thuộc cloud: dùng được cho on-premise, GCP, Azure, máy lập trình viên | Đang HTTP: phải sửa Docker/containerd trên mọi máy và node |
| Proxy nhiều registry công khai sau một hostname | Không quét lỗ hổng, không tag bất biến theo repo, không ký image |
| User/mật khẩu đơn giản cho máy ngoài AWS | Mật khẩu dài hạn (CE không có token), phải tự xoay vòng |

**ECR**

| Ưu điểm | Nhược điểm |
|---|---|
| Không phải vận hành, HA sẵn, HTTPS sẵn | Gắn với AWS; máy ngoài AWS cần IAM credential và làm mới token 12 giờ |
| Node EKS pull bằng IAM role (node group đã có `AmazonEC2ContainerRegistryReadOnly`), **không cần imagePullSecret, không cần insecure registry** | Phải tạo repository cho từng image (Terraform hoặc creation template) |
| Quét lỗ hổng, tag bất biến, lifecycle policy, KMS, replication, CloudTrail | Chỉ OCI: Maven/npm/PyPI... vẫn cần Nexus (hoặc CodeArtifact) |
| Trả theo dung lượng thực dùng | Pull ra ngoài region/Internet tốn phí truyền dữ liệu |

### Khuyến nghị cho hệ thống này

Mô hình **kết hợp** (phổ biến ở ngân hàng chạy trên AWS):

| Loại image | Nơi lưu |
|---|---|
| Image ứng dụng để **deploy lên EKS** (staging, prod) | **ECR**: tag `IMMUTABLE`, scan on push (Enhanced nếu có Inspector), lifecycle policy, KMS; node pull bằng IAM role |
| Image nền và image công cụ từ kho công khai | **Nexus** `docker-group` (proxy, cache), hoặc ECR pull-through cache nếu chỉ dùng trong AWS |
| Image dùng ngoài AWS (on-premise, cloud khác, máy lập trình viên) | Nexus |
| Maven, npm, PyPI, NuGet, gói OS, Conan, raw | Nexus |

Lợi ích trực tiếp: giải quyết luôn câu hỏi còn treo của phần CD (chọn A: HTTPS hay B: cấu hình containerd HTTP để node pull image). Với ECR, node EKS pull được ngay mà không phải sửa node.

Các bước nếu chọn ECR cho image ứng dụng:

1. Terraform: `aws_ecr_repository` cho mỗi app (`image_tag_mutability = "IMMUTABLE"`, `image_scanning_configuration { scan_on_push = true }`, `encryption_configuration` KMS) + `aws_ecr_lifecycle_policy` (giữ 30 image gần nhất, xoá untagged sau 7 ngày).
2. Quyền push cho pipeline: IRSA cho service account của pod agent Jenkins (policy `ecr:GetAuthorizationToken` + push vào đúng repository), thay credential `docker-user-internal`.
3. Jenkinsfile: `aws ecr get-login-password | docker login --username AWS --password-stdin 609320954321.dkr.ecr.ap-southeast-1.amazonaws.com`, push `609320954321.dkr.ecr.ap-southeast-1.amazonaws.com/dev-backend/shopping-cart:<tag>` (tag không trùng, ví dụ `<version>-<commit>`, vì repository bất biến).
4. Manifest/Helm values của app trỏ image ECR; không cần `imagePullSecrets`.
5. Giữ Trivy ở pipeline (chặn trước khi push) và dùng ECR scan để theo dõi CVE mới sau khi đã push.
