# 4. So sánh Jenkins với các công cụ CI/CD phổ biến

[← Mục lục](README.md)

## 4.1. Bảng so sánh

| Tiêu chí | **Jenkins** (đang dùng) | **GitLab CI/CD** | **GitHub Actions** | **Tekton / Argo Workflows** | **AWS CodeBuild + CodePipeline** | **Azure DevOps Pipelines** |
|---|---|---|---|---|---|---|
| Mô hình | Self-hosted, mã nguồn mở | SaaS hoặc self-hosted (đã có GitLab trong cụm) | SaaS (runner có thể self-hosted) | Kubernetes-native, mã nguồn mở | Dịch vụ AWS managed | SaaS (agent có thể self-hosted) |
| Định nghĩa pipeline | `Jenkinsfile` (Groovy: declarative/scripted) | `.gitlab-ci.yml` (YAML) | `.github/workflows/*.yml` (YAML) | CRD YAML (Task, Pipeline / Workflow) | `buildspec.yml` + cấu hình pipeline | `azure-pipelines.yml` (YAML) |
| Gắn với SCM | Bất kỳ SCM nào | Chặt với GitLab | Chặt với GitHub | Bất kỳ SCM nào (qua trigger) | CodeCommit, GitHub, GitLab, Bitbucket | Azure Repos, GitHub, Bitbucket |
| Agent / runner | Pod Kubernetes động, VM, máy vật lý, Windows, macOS | GitLab Runner (Kubernetes, Docker, shell) | Runner của GitHub hoặc self-hosted (ARC trên Kubernetes) | Mỗi bước là một pod | Container managed của AWS | Agent managed hoặc self-hosted |
| Hệ sinh thái mở rộng | **Rất lớn**: khoảng 2.000 plugin | Tích hợp sẵn nhiều tính năng (registry, SAST, DAST…) | Marketplace lớn với hàng chục nghìn action | Catalog Task (Tekton Hub, Artifact Hub) | Tích hợp sâu với dịch vụ AWS | Extension Marketplace |
| Bảo mật tích hợp sẵn | Cần plugin và tự cấu hình | SAST, DAST, dependency/container scanning, secret detection (một phần cần bản trả phí) | Dependabot, CodeQL, secret scanning (bản riêng tư cần GHAS) | Tự tích hợp; Tekton Chains (ký, provenance theo SLSA) | IAM, KMS, VPC, CloudTrail | Defender for DevOps, tích hợp Entra ID |
| Quản lý secret | Credentials store, Kubernetes Secret (JCasC), Vault plugin | CI/CD variables (masked/protected), Vault, external secrets | Encrypted secrets, OIDC tới cloud | Kubernetes Secret, Vault | Secrets Manager, Parameter Store | Key Vault, variable groups |
| Phê duyệt / cổng chặn | `input`, Quality Gate qua plugin | Protected environments, approval rules (một phần trả phí) | Environments + required reviewers | Tự xây dựng | Manual approval action | Approvals and checks |
| GitOps / CD lên Kubernetes | Qua Argo CD/Flux (push GitOps repo) | Agent for Kubernetes, kết hợp Argo/Flux | Kết hợp Argo/Flux | Argo CD (cùng hệ sinh thái Argo) | CodeDeploy, kết hợp Argo/Flux | Environments Kubernetes, kết hợp Argo/Flux |
| Khả năng mở rộng (HA) | Một controller; scale bằng nhiều controller. HA cần CloudBees | Runner scale tốt; GitLab HA phức tạp khi self-hosted | SaaS tự scale | Scale theo Kubernetes, không có controller tập trung | Managed, tự scale | SaaS tự scale |
| Vận hành | **Nặng**: nâng cấp plugin, sao lưu, bảo mật | Trung bình (self-hosted) / nhẹ (SaaS) | Nhẹ | Trung bình: cần hiểu Kubernetes và CRD | Rất nhẹ | Nhẹ |
| Chi phí | Miễn phí phần mềm; tốn công vận hành và hạ tầng | Free/Premium/Ultimate | Theo phút chạy (repo riêng tư) hoặc self-hosted runner | Miễn phí phần mềm | Theo phút build | Theo user và parallel job |
| Phù hợp nhất | Cần linh hoạt tối đa, nhiều SCM, pipeline phức tạp, hệ thống cũ | Đã dùng GitLab, muốn một nền tảng DevSecOps duy nhất | Mã nguồn trên GitHub | Nền tảng thuần Kubernetes, platform engineering | Workload chủ yếu trên AWS | Doanh nghiệp dùng Microsoft |

## 4.2. Ưu và nhược điểm của Jenkins trong hệ thống này

**Ưu điểm:**
- **Linh hoạt nhất**: `Jenkinsfile` là code Groovy, nên viết được pipeline nhiều nhánh, có phê duyệt và logic phức tạp (ví dụ promote/rollback staging).
- **Không phụ thuộc SCM**: có thể build cả GitLab lẫn GitHub; dễ chuyển SCM sau này.
- **Hệ sinh thái plugin lớn**: SonarQube, Kubernetes, Nexus, AWS, Vault đều có plugin.
- **Self-hosted hoàn toàn trong cụm**: mã nguồn và artifact không ra khỏi hạ tầng của mình (thuận lợi cho tuân thủ).
- **Agent động trên Kubernetes**: tận dụng chung cụm EKS và Cluster Autoscaler.

**Nhược điểm:**
- **Vận hành nặng**: phải tự nâng cấp core và plugin, theo dõi cảnh báo bảo mật (đã gặp: plugin lệch phiên bản, agent sai JDK, 6 cảnh báo core).
- **Plugin là rủi ro**: phần lớn lỗ hổng Jenkins nằm ở plugin, nên phải ghim phiên bản và audit định kỳ.
- **Không có HA active-active** ở bản mã nguồn mở.
- **Bảo mật không có sẵn**: phải tự lắp SSO, MFA, RBAC, audit log, HTTPS (xem [phần 3](03-tich-hop-va-bao-mat.md)).
- **Groovy/CPS có độ khó riêng**: lỗi serialization, script approval, khó test pipeline.

## 4.3. Khi nào nên cân nhắc công cụ khác

| Tình huống | Gợi ý |
|---|---|
| Toàn bộ code nằm trên GitLab và muốn giảm số tool phải vận hành | **GitLab CI** với Runner Kubernetes trong cụm: pipeline ngay trong repo, có sẵn merge request pipeline và environments. Có thể chuyển dần từng project |
| Cần một nền tảng build thuần Kubernetes, có ký artifact và provenance (SLSA) | **Tekton** (+ Tekton Chains) hoặc **Argo Workflows**, dùng chung với Argo CD |
| Muốn giảm tối đa công vận hành, workload chủ yếu trên AWS | **CodeBuild + CodePipeline** |
| Pipeline phức tạp, nhiều hệ thống cũ, nhiều SCM | Giữ **Jenkins**, nhưng chuẩn hoá bằng Shared Library, JCasC, plugin ghim phiên bản và nhiều controller |

**Đề xuất cho hệ thống hiện tại:** giữ Jenkins cho các pipeline đã có, vì đã ổn định và cấu hình hoàn toàn bằng code. Song song đó, đánh giá **GitLab CI** cho các project mới: GitLab đã chạy sẵn trong cụm, nên không phải thêm hạ tầng; chỉ cần cài GitLab Runner (Kubernetes executor). Phần CD vẫn dùng chung **Argo CD** cho cả hai.
