# 4. So sánh GitLab với các nền tảng quản lý mã nguồn khác

[← Mục lục GitLab](README.md)

## 4.1. Bảng so sánh

So sánh các bản **tự host** (self-managed) phù hợp ngân hàng, kèm bản cloud để tham khảo.

| Tiêu chí | GitLab CE (đang dùng) | GitLab Premium/Ultimate | GitHub Enterprise Server / Cloud | Bitbucket Data Center | Azure DevOps Server | Gitea / Forgejo |
|---|---|---|---|---|---|---|
| Tự host | Có (miễn phí) | Có (license theo user) | Server: có; Cloud: SaaS (có data residency) | Có | Có (Windows Server) | Có, rất nhẹ |
| Chạy trên Kubernetes | Chart chính thức (cloud-native) | Như CE | Server: appliance VM, không chạy trên K8s | Có chart (Data Center) | Không | Có chart cộng đồng |
| Thành phần ngoài cần có | PostgreSQL, Redis, object storage | Như CE | Đi kèm trong appliance | PostgreSQL, Elasticsearch/OpenSearch, shared storage | SQL Server | Một DB (PostgreSQL/MySQL/SQLite) |
| CI/CD tích hợp | GitLab CI (mạnh) | Thêm merge train, pipeline compliance | GitHub Actions (mạnh, marketplace lớn) | Bitbucket Pipelines chỉ có trên Cloud; DC dùng Bamboo/Jenkins | Azure Pipelines (mạnh) | Gitea/Forgejo Actions (tương thích Actions, còn non) |
| Container/Package registry | Có | Có | Có (Packages) | Không (dùng Nexus/Artifactory) | Azure Artifacts | Có |
| Duyệt MR/PR bắt buộc, CODEOWNERS bắt buộc | Duyệt tuỳ chọn; protected branch có | Có (approval rules, CODEOWNERS) | Có (branch protection, rulesets) | Có | Có (branch policies) | Có (cơ bản) |
| Push rules (chặn secret, ép format commit) | Không | Có | Push protection (Secret scanning, cần GHAS) | Có (hooks) | Một phần | Hạn chế |
| SSO SAML/OIDC, LDAP | Đăng nhập SAML/OIDC, LDAP | + SAML Group Sync, SCIM | Có (Enterprise) | Có (Crowd/SAML) | AD/Entra ID | OIDC, LDAP |
| Audit log đầy đủ, streaming | Hạn chế | Có (Audit Events, streaming ở Ultimate) | Có, có streaming | Có | Có | Cơ bản |
| Quét bảo mật (SAST, secret, dependency, container) | Template cơ bản | Ultimate: dashboard, chính sách, vulnerability management | GHAS (trả thêm) | Qua công cụ ngoài (Snyk, SonarQube) | Qua extension / GHAS for Azure DevOps | Qua công cụ ngoài |
| HA / DR | Tự xây (Gitaly đơn) | Gitaly Cluster, **Geo** (bản sao chỉ đọc, DR) | Server: HA replica, backup-utils | Data Center: cluster nhiều node | SQL Server AlwaysOn | Tự xây |
| Chi phí | Hạ tầng | Hạ tầng + license/user/năm (Ultimate đắt) | License/user/năm (+ GHAS) | License/user/năm | License/user (Server + CAL) | Hạ tầng |
| Độ phức tạp vận hành | Cao (nhiều thành phần) | Cao | Thấp–vừa (appliance) | Vừa–cao | Vừa | Thấp |

Ghi chú: **AWS CodeCommit** đã ngừng nhận khách hàng mới từ 7/2024, không nên chọn cho hệ thống mới.

## 4.2. Ưu và nhược điểm của GitLab trong hệ thống này

**Ưu điểm:**

- Một nền tảng gồm repo, MR, issue, CI (GitLab Runner), registry, package, Terraform state. Có thể dần thay một phần Jenkins/Nexus nếu muốn gom công cụ.
- Chart cloud-native chạy trên chính EKS đang có; tách được dữ liệu ra RDS/ElastiCache/S3 (dịch vụ AWS quản lý, mã hoá, backup tự động).
- CE miễn phí, đủ cho quản lý mã nguồn, protected branch, LDAP/SAML login, CI.
- Tích hợp sẵn với Jenkins (`gitlab-branch-source`), Argo CD, SonarQube.
- Có đường nâng cấp lên Premium/Ultimate trên cùng cài đặt (đổi `global.edition: ee` + license), không phải di chuyển dữ liệu.

**Nhược điểm:**

- Nhiều thành phần (webservice, sidekiq, gitaly, shell, registry, kas, toolbox) và nhiều dịch vụ ngoài, nên vận hành và nâng cấp phức tạp hơn Gitea hay GitHub appliance.
- Nâng cấp phải theo **upgrade path** (các bản dừng bắt buộc), không nhảy thẳng nhiều bản; nâng major của chart có thay đổi phá vỡ (ví dụ chart 10.x bỏ PostgreSQL/Redis/MinIO đi kèm).
- Gitaly trong Kubernetes là điểm lỗi đơn; HA thật sự cho Gitaly cần chạy ngoài cụm.
- Các tính năng tuân thủ quan trọng với ngân hàng (approval rules bắt buộc, push rules, audit events đầy đủ, SAML group sync, Geo) nằm ở **Premium/Ultimate**.

## 4.3. Khi nào nên cân nhắc lựa chọn khác

| Tình huống | Gợi ý |
|---|---|
| Ngân hàng cần audit đầy đủ, duyệt bắt buộc, chặn secret khi push, DR | **GitLab Premium** (hoặc Ultimate nếu muốn gom quét bảo mật và quản lý lỗ hổng), giữ nguyên hạ tầng hiện tại |
| Tổ chức đã dùng Microsoft 365/Entra ID và Azure Pipelines | Azure DevOps (Services hoặc Server) |
| Muốn hệ sinh thái Actions lớn, chấp nhận SaaS hoặc appliance | GitHub Enterprise (Cloud có data residency, hoặc Server) |
| Đã dùng Jira/Confluence Data Center, cần tích hợp chặt | Bitbucket Data Center + Jenkins/Bamboo |
| Team nhỏ, chỉ cần Git server nhẹ, CI ở Jenkins | Gitea/Forgejo (ít tài nguyên, vận hành đơn giản) |
| Giữ GitLab CE, bù phần thiếu | Protected branch + quy ước review; Jenkins/SonarQube/Trivy cho quét; GitHub push protection/`gitleaks` trong pipeline cho secret; log tập trung cho audit |
