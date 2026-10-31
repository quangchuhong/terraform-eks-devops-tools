# Hạ tầng chạy build: Jenkins agent và GitLab Runner

Tài liệu mô tả kiến trúc và cách đã triển khai lớp **chạy build** của nền tảng CI trên EKS `eks-cluster-ver1`:

- node group riêng `ci_agents` cho mọi pod build (Jenkins agent và job của GitLab Runner);
- artifact của Jenkins lưu trên S3;
- log build (Console Output) và metadata build của Jenkins lưu trữ trên S3 có Object Lock;
- GitLab Runner (Kubernetes executor) dùng chung node group CI.

Trạng thái: **đã triển khai và kiểm tra ngày 31/10/2026** (xem [phần 6](#6-kết-quả-kiểm-tra-khi-triển-khai)).

Tài liệu liên quan:

- Jenkins: [kiến trúc](../jenkins/01-kien-truc-va-cau-hinh.md), [sizing và scale](../jenkins/02-sizing.md), [hướng dẫn triển khai](../jenkins/05-huong-dan-trien-khai.md) (5.12 artifact S3 và node group, 5.14 log build lên S3), [Shared Library](../jenkins/07-shared-library.md).
- Cài nhanh các tool: [`helm-install/README.md`](../../helm-install/README.md).
- Manifest GitLab Runner sinh từ `helm template`: [gitlab-runner-manifest.md](gitlab-runner-manifest.md).

## 1. Vì sao tách node group cho build

Trước khi tách, pod build chạy chung node với GitLab, Nexus, SonarQube và Jenkins controller. Các sự cố đã gặp:

| Sự cố | Nguyên nhân |
|---|---|
| Pod build bị **Evicted** (`ephemeral-storage`) | docker-in-docker, Trivy Java DB (~3.7GB), cache Maven ghi đầy ổ gốc của node đang chạy các tool khác |
| Controller và GitLab chậm khi nhiều build chạy cùng lúc | Build (Maven, docker build) dùng hết CPU/RAM của node |
| Rủi ro bảo mật | Pod `docker:dind` chạy **privileged** nằm cùng node với Jenkins controller (chứa credentials) và GitLab |

Nguyên tắc sau khi tách:

1. **Node thường** (`eks_nodes`): chỉ chạy các tool (GitLab, Jenkins controller, Nexus, SonarQube, Trivy server) và runner manager.
2. **Node CI** (`ci_agents`): chỉ chạy pod build. Có **taint**, nên các tool không bao giờ lên đây; pod build có **nodeSelector + toleration**, nên chỉ lên đây.
3. Pod build là **tạm thời**: mỗi build/job một pod, xong là xoá. Node CI không giữ dữ liệu cần sao lưu (không có volume EBS).

## 2. Kiến trúc

### 2.1. Tổng quan

```
                               EKS eks-cluster-ver1 (ap-southeast-1)
┌──────────────────────────────────────────────────────┐   ┌───────────────────────────────────────────┐
│ Node group eks_nodes (t3.xlarge, 3–10, 1 node/AZ)    │   │ Node group ci_agents (m6i/m5.xlarge, 1–10)│
│ không taint                                          │   │ label  workload=ci-agents                 │
│                                                      │   │ taint  workload=ci-agents:NoSchedule      │
│  jenkins-0 (StatefulSet)                             │   │                                           │
│   ├─ jenkins (controller) ── IRSA ──┐                │   │  Pod agent Jenkins (mỗi build một pod)    │
│   ├─ config-reload                  │                │   │   jnlp │ maven │ maven17 │ docker │ trivy │
│   └─ build-log-archiver (sidecar) ──┤                │   │                                           │
│        PVC jenkins 50Gi (EBS gp3)   │                │   │  Pod job GitLab (mỗi job một pod)         │
│                                     │                │   │   build │ helper (│ service)              │
│  gitlab-runner (manager, Deployment)│                │   │                                           │
│  GitLab, Nexus, SonarQube, Trivy    │                │   │  Ổ gốc 100 GiB, không có volume EBS       │
└─────────────────────────────────────┼────────────────┘   └───────────────────────────────────────────┘
                                      │ IRSA role eks-cluster-ver1-jenkins-artifacts
                                      ▼
            ┌───────────────────────────────────────────┐   ┌───────────────────────────────────────────┐
            │ S3 jenkins-609320954321-artifacts         │   │ S3 jenkins-609320954321-build-logs        │
            │ archiveArtifacts, stash                   │   │ log + build.xml của build đã xong         │
            │ SSE-KMS, versioning, lifecycle 400 ngày   │   │ SSE-KMS, Object Lock 365 ngày (GOVERNANCE)│
            └───────────────────────────────────────────┘   └───────────────────────────────────────────┘
```

### 2.2. Node group `ci_agents`

| Thuộc tính | Giá trị | Ghi chú |
|---|---|---|
| Instance | `m6i.xlarge`, `m5.xlarge` (4 vCPU, 16 GiB) | `var.ci_agent_instance_types` |
| Kiểu giá | `ON_DEMAND` | `var.ci_agent_capacity_type`; đổi `SPOT` để giảm 60–70% chi phí (build chịu được bị ngắt) |
| Số node | min 1, max 10 | `var.ci_agent_min_size` / `max_size`; Cluster Autoscaler tự thêm/bớt |
| Ổ gốc | 100 GiB gp3, mã hoá | `var.node_disk_size`; chứa image, layer docker-in-docker, cache |
| Label | `workload=ci-agents` | Pod build chọn node bằng `nodeSelector` |
| Taint | `workload=ci-agents:NoSchedule` | Chặn mọi pod không có toleration |
| Đa AZ | Một node group trải trên các AZ | An toàn vì node CI không gắn volume EBS (không có ràng buộc AZ như `eks_nodes`) |

Cấu hình trong `eks.tf` (`eks_managed_node_groups.ci_agents`) và `variables.tf`. EKS tự gắn tag auto-discovery cho Auto Scaling Group, nên Cluster Autoscaler nhận node group này mà không cần cấu hình thêm.

### 2.3. Cơ chế đặt pod lên node CI

| Loại pod | Nơi khai báo `nodeSelector` + toleration |
|---|---|
| Agent Jenkins của pipeline tự định nghĩa `podTemplate` (như `shopping-cart`) | Trong **Jenkinsfile** (`podSpec.nodeSelector` + `yaml` toleration) |
| Agent Jenkins dùng template mặc định | `helm-install/jenkins/jenkins/values.yaml` (`agent.nodeSelector`, `agent.yamlTemplate`) |
| Agent Jenkins qua Shared Library `ci-lib` | `vars/ciPod.groovy` (tự thêm cho mọi app) |
| Job GitLab Runner | `helm-install/gitlab-runner/values.yaml` (`[runners.kubernetes.node_selector]`, `node_tolerations`) |
| Runner manager (`gitlab-runner` Deployment) | Không khai báo: chạy ở node thường (nhẹ, chỉ nhận job và tạo pod) |

**Quan trọng:** `podTemplate` trong Jenkinsfile **không kế thừa** `nodeSelector` của template mặc định. Pipeline nào tự định nghĩa `podTemplate` phải tự khai báo, nếu không pod build sẽ chạy ở node thường (đã gặp khi triển khai, xem [7](#7-sự-cố-đã-gặp-và-cách-xử-lý)). Dùng `ci-lib` thì không phải nhớ việc này.

Ví dụ trong Jenkinsfile:

```groovy
def podSpec = [
  nodeSelector: 'workload=ci-agents',
  yaml: '''
spec:
  tolerations:
    - key: workload
      operator: Equal
      value: ci-agents
      effect: NoSchedule
''',
  containers: [ /* ... */ ]
]
```

### 2.4. Jenkins agent

- Mỗi build tạo một pod (plugin Kubernetes), kết nối về controller qua Service `jenkins-agent:50000`; build xong pod bị xoá.
- Pod của `shopping-cart` có 5 container: `jnlp` (JDK 21, cùng Java với controller), `maven` (JDK 8, build), `maven17` (Sonar scanner), `docker` (dind, privileged), `trivy`.
- Workspace dùng chung giữa các container trong pod (emptyDir).
- Controller không chạy build (`Executors on built-in = 0`).

### 2.5. GitLab Runner

| Thành phần | Cấu hình (`helm-install/gitlab-runner/values.yaml`) |
|---|---|
| Chart | `gitlab/gitlab-runner` **0.94.0** (runner **19.5.0**, khớp GitLab 19.5.3) |
| Runner manager | Deployment `gitlab-runner`, namespace `gitlab-runner`, node thường; `concurrent = 10`; `request_concurrency = 4`; chờ job xong tối đa 1 giờ khi bị thay thế |
| Đăng ký | Instance runner tạo trên GitLab (tags `eks`, `k8s`, không chạy job không có tag); token `glrt-…` trong Secret `gitlab-runner/gitlab-runner-token` |
| Pod job | Namespace `gitlab-runner`, node CI; **không privileged**, `allow_privilege_escalation = false` |
| Tài nguyên pod job | build: request 500m/1Gi, limit 2 CPU/4Gi, ephemeral 2–20Gi; helper: 50m/64Mi (limit 256Mi); service: 100m/256Mi (limit 1Gi) |
| Quyền Kubernetes | Role tối thiểu trong namespace `gitlab-runner`: pods (create/delete/get/list/watch), pods/exec, pods/attach, pods/log, secrets, configmaps, services, events, serviceaccounts (get) |
| IAM | Không gắn IAM role cho pod job (không cần quyền AWS) |

Build image trong GitLab CI: pod job không privileged nên **không dùng `docker:dind`**; dùng Kaniko hoặc BuildKit rootless (ví dụ ở [5.12](../jenkins/05-huong-dan-trien-khai.md#gitlab-runner-dùng-chung-node-group-ci)).

### 2.6. Artifact Jenkins trên S3

| Thành phần | Cấu hình |
|---|---|
| Plugin | `artifact-manager-s3:1002.v005e958510dd` (+ `aws-global-configuration`, `oss-symbols-api`), JCasC `artifact-s3` |
| Bucket | `jenkins-609320954321-artifacts`, prefix `jenkins/` → `jenkins/<job>/<branch>/<build>/artifacts/<file>` |
| Mã hoá | SSE-KMS, key `alias/eks-cluster-ver1-jenkins-artifacts` (xoay vòng hằng năm), bucket key |
| Vòng đời | Standard-IA sau 30 ngày, Glacier IR sau 90 ngày, xoá sau 400 ngày |
| Bảo vệ | Chặn public, chỉ cho TLS, versioning |
| Quyền | IRSA role `eks-cluster-ver1-jenkins-artifacts`, chỉ service account `jenkins/jenkins` assume được |

Luồng: `archiveArtifacts`/`stash` → controller ký URL S3 → agent tải lên trực tiếp S3 → giao diện Jenkins tải về qua URL đã ký. Artifact không còn đi qua và không nằm trên `JENKINS_HOME`.

### 2.7. Log build trên S3

| Thành phần | Cấu hình |
|---|---|
| Sidecar | `build-log-archiver` (`amazon/aws-cli:2.38.1`), non-root, root filesystem read-only, mount `JENKINS_HOME` read-only (`values-build-logs.yaml`) |
| Cách chạy | Mỗi 120 giây tìm build **đã xong** (`build.xml` có `<result>`, không có `<completed>false</completed>`), tải `log` rồi `build.xml`, mỗi build một lần |
| Bucket | `jenkins-609320954321-build-logs`, prefix `jenkins/` → `jenkins/jobs/<job>/branches/<branch>/builds/<n>/{log,build.xml}` |
| Bất biến | **Object Lock GOVERNANCE 365 ngày**; role chỉ có quyền ghi/đọc, **không có quyền xoá** |
| Vòng đời | IA 30 ngày, Glacier IR 90 ngày, xoá sau 400 ngày |
| Khi lỗi | Sidecar không bao giờ tự thoát (chỉ ghi log và thử lại), nên không làm `jenkins-0` mất Ready |

Chi tiết thiết kế: [5.14](../jenkins/05-huong-dan-trien-khai.md#514-lưu-trữ-log-build-lên-s3).

### 2.8. Bảo mật (tóm tắt)

| Biện pháp | Đáp ứng |
|---|---|
| Pod build privileged (`docker:dind`) tách khỏi node chạy controller, GitLab, Nexus | Giảm phạm vi ảnh hưởng nếu một build bị chiếm quyền |
| Job GitLab không privileged | Mặc định an toàn cho GitLab CI |
| IRSA thay access key; role theo nguyên tắc tối thiểu | PCI DSS 7.2, 8.6 |
| Bucket mã hoá KMS, chỉ TLS, chặn public | PCI DSS 3.5, 4.2 |
| Log build bất biến 12 tháng (Object Lock) | PCI DSS 10.3.3, 10.5.1 |
| Token runner, mật khẩu chỉ nằm trong Kubernetes Secret, nhập bằng `read -s` | Không lộ secret trong Git, chat hay lịch sử shell |

## 3. File cấu hình

| File | Nội dung |
|---|---|
| `eks.tf`, `variables.tf` (`ci_agent_*`, `node_disk_size`) | Node group `ci_agents` |
| `jenkins-storage.tf`, `variables.tf` (`jenkins_artifacts_retention_days`) | KMS key, bucket artifacts, IRSA role |
| `jenkins-build-logs.tf`, `variables.tf` (`jenkins_build_logs_*`) | Bucket log (Object Lock), quyền ghi cho role IRSA |
| `helm-install/jenkins/jenkins/values.yaml` | Plugin (127, ghim phiên bản), JCasC `artifact-s3`, IRSA annotation, agent mặc định lên node CI, `persistence.size: 50Gi` |
| `helm-install/jenkins/jenkins/values-build-logs.yaml` | Sidecar `build-log-archiver` |
| `helm-install/gitlab-runner/values.yaml` | GitLab Runner |
| `Jenkinsfile` của app (`shopping-cart`) | `nodeSelector` + toleration trong `podTemplate` |

## 4. Hướng dẫn cài đặt (đúng thứ tự đã làm)

Chạy từ thư mục repo `terraform-eks-devops-tools` trên máy có quyền AWS và `kubectl` vào cluster.

### Bước 0. Đồng bộ code

```bash
git config pull.rebase true
git status --short
git pull origin main
```

Nếu `git status` có file đã sửa (ví dụ `.terraform.lock.hcl` sau `terraform init`), commit trước rồi mới pull. Không commit file chứa secret (`terraform.tfvars`, `*.tfstate`).

### Bước 1. Terraform: node group CI và hai bucket

```bash
terraform plan -out tf.plan | tee plan.txt
grep -E "will be (created|updated|destroyed|replaced)|must be replaced|Plan:" plan.txt
```

Plan mong đợi: **27 to add, 0 to destroy**. Gồm node group `ci_agents` (IAM role, launch template), KMS key/alias, hai bucket và cấu hình đi kèm (Object Lock cho bucket log), IAM role `jenkins_artifacts` và 2 role policy.

Có thể thấy **4 to change** trên `aws_iam_role.gitlab_runner`, `aws_iam_role.nexus`, `module.lb_role` (role và policy). Đây là **drift giả**: các data source đó có `depends_on = [module.eks]`, nên khi `module.eks` thay đổi, Terraform hoãn đọc đến lúc apply và hiện policy là `(known after apply)`. Kiểm tra:

```bash
terraform show -no-color tf.plan > plan-detail.txt
grep -nE "^\s+\) -> \(known after apply\)|~ (assume_role_policy|policy) " plan-detail.txt
```

Nếu mọi policy đều kết thúc bằng `-> (known after apply)` thì an toàn. Khi apply, nội dung được tính lại giống hệt (lần triển khai thực tế: `27 added, 0 changed, 0 destroyed`).

```bash
terraform apply tf.plan
kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl describe nodes -l workload=ci-agents | grep -E "^Name:|Taints:"
aws s3api get-object-lock-configuration --bucket jenkins-609320954321-build-logs --region ap-southeast-1
```

Mong đợi: một node `ci-agents` `Ready` với taint `workload=ci-agents:NoSchedule`; Object Lock `GOVERNANCE`, 365 ngày.

### Bước 2. Jenkins: plugin S3, IRSA, sidecar log

**Luôn truyền đủ hai file values** (thiếu file thứ hai thì sidecar bị gỡ):

```bash
helm upgrade jenkins ./helm-install/jenkins/jenkins -n jenkins -f ./helm-install/jenkins/jenkins/values.yaml -f ./helm-install/jenkins/jenkins/values-build-logs.yaml --timeout 15m
kubectl -n jenkins wait --for=condition=Ready pod/jenkins-0 --timeout=15m
kubectl -n jenkins get pod jenkins-0
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'env | grep -E "AWS_ROLE_ARN|AWS_WEB_IDENTITY_TOKEN_FILE"'
kubectl -n jenkins logs jenkins-0 -c build-log-archiver --tail=20
```

Mong đợi:

- `jenkins-0` `3/3 Running` (jenkins, config-reload, build-log-archiver), mất khoảng 3–5 phút;
- `AWS_ROLE_ARN=arn:aws:iam::609320954321:role/eks-cluster-ver1-jenkins-artifacts`;
- log sidecar: `seeded 0 archived builds…`, rồi `archived jobs/…` cho các build cũ đã xong.

### Bước 3. Jenkinsfile của app có `nodeSelector`

Đẩy Jenkinsfile mới lên GitLab cho mọi nhánh Jenkins build (repo app có hai remote: `origin` = GitHub, `gitlab` = GitLab):

```bash
cd <thư-mục>/shopping-cart
git checkout main
git pull origin main
grep -n "nodeSelector" Jenkinsfile
git push gitlab main
git fetch gitlab
git checkout -B develop gitlab/develop
git merge main
git push gitlab develop
git checkout main
```

### Bước 4. Ghim plugin mới

```bash
./helm-install/jenkins/security-audit/run.sh plugins.groovy > /tmp/plugins-now.txt
sed 's/^ *- //' /tmp/plugins-now.txt | while IFS=: read -r name ver; do grep -qE "^    - ${name}:" helm-install/jenkins/jenkins/values.yaml || echo "    - ${name}:${ver}"; done
./helm-install/jenkins/security-audit/run.sh
```

Thêm các plugin in ra vào `installPlugins`, đổi `:latest` thành phiên bản đang chạy, commit. Audit phải không có `Core warnings` / `Plugin warnings`. Không cần `helm upgrade` ngay nếu phiên bản ghim trùng bản đang chạy.

### Bước 5. GitLab Runner

1. Trên GitLab: **Admin → CI/CD → Runners → New instance runner**. Tags: `eks,k8s`; bỏ chọn *Run untagged jobs*; **Create runner**; copy token `glrt-…` (chỉ hiện một lần, **không dán vào chat hay file**).
2. Tạo Secret và cài chart:

```bash
kubectl create namespace gitlab-runner
read -r -s -p "Runner token (glrt-...): " RUNNER_TOKEN; echo
kubectl -n gitlab-runner create secret generic gitlab-runner-token --from-literal=runner-registration-token="" --from-literal=runner-token="$RUNNER_TOKEN"
unset RUNNER_TOKEN
helm repo add gitlab https://charts.gitlab.io
helm repo update gitlab
helm upgrade --install gitlab-runner gitlab/gitlab-runner --version 0.94.0 -n gitlab-runner -f ./helm-install/gitlab-runner/values.yaml
kubectl -n gitlab-runner rollout status deploy/gitlab-runner
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=20
```

Mong đợi: `Configuration loaded`, `max_builds=10`, không có `403`/`invalid token`/`Long polling issues`; runner **Online** trên GitLab.

Các cảnh báo sau là bình thường khi chạy trong container: `Running in user-mode`, `listen_address not defined`, `Runner namespace "gitlab-runner" was found in runners.config template`.

### Bước 6. Kiểm tra đầu-cuối

**Jenkins:** chạy một build (`shopping-cart` → `main` → **Build Now**):

```bash
kubectl -n jenkins get pods -o wide -w
aws s3 ls s3://jenkins-609320954321-artifacts/jenkins/ --recursive | grep trivy
kubectl -n jenkins logs jenkins-0 -c build-log-archiver --tail=3
aws s3 cp s3://jenkins-609320954321-build-logs/jenkins/jobs/shopping-cart/branches/main/builds/<n>/build.xml - | grep -m1 '<result>'
```

**GitLab Runner:** project thử với `.gitlab-ci.yml`:

```yaml
test-runner:
  tags: [eks]
  image: alpine:3.22
  script:
    - echo "pod=$(hostname)"
    - sleep 30
```

```bash
kubectl -n gitlab-runner get pods -o wide
```

## 5. Vận hành

### 5.1. Lệnh kiểm tra thường dùng

```bash
kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl get pods -A -o wide --field-selector spec.nodeName=$(kubectl get nodes -l workload=ci-agents -o jsonpath='{.items[0].metadata.name}')
kubectl top nodes -l workload=ci-agents
kubectl -n jenkins logs jenkins-0 -c build-log-archiver --tail=10
kubectl -n gitlab-runner logs deploy/gitlab-runner --tail=20
```

### 5.2. Năng lực và scale

| Nội dung | Giá trị / cách làm |
|---|---|
| Sức chứa 1 node `m6i.xlarge` | Khoảng 2–3 pod `shopping-cart` (mỗi pod request khoảng 1,2 CPU, 2,3 GiB, chưa tính dind/trivy không đặt request) hoặc khoảng 6 job GitLab mặc định |
| Thêm node | Cluster Autoscaler tự thêm khi có pod build `Pending` vì thiếu tài nguyên (khoảng 2–4 phút cho node mới) |
| Bớt node | Autoscaler bớt node rỗng sau khoảng 10 phút; luôn giữ `ci_agent_min_size` (1) |
| Nhiều build hơn | Tăng `ci_agent_max_size`; hoặc instance lớn hơn (`m6i.2xlarge`) để giảm thời gian kéo image |
| Giảm chi phí | `ci_agent_capacity_type = "SPOT"` (nhiều loại instance trong `ci_agent_instance_types` để ít bị thu hồi); `ci_agent_min_size = 0` nếu chấp nhận build đầu tiên chờ 2–4 phút |
| Build đầu tiên trên node mới chậm | Phải kéo image (Maven, dind, Trivy) và Trivy Java DB; các build sau dùng cache trên ổ gốc |

Đổi biến trong `terraform.tfvars`, rồi `terraform plan` / `apply`. Thay đổi instance hoặc kiểu giá sẽ tạo node mới và thay dần node cũ (build đang chạy trên node cũ có thể bị ngắt, nên làm ngoài giờ build).

### 5.3. Bảo trì

| Việc | Cách làm |
|---|---|
| Nâng runner | Đổi `--version` chart và `image.tag` theo phiên bản GitLab (chart `0.(minor)` tương ứng runner `x.y`), `helm upgrade`; job đang chạy được chờ tối đa 1 giờ |
| Xoay token runner | GitLab: runner → **Reset token**; cập nhật Secret (`kubectl -n gitlab-runner create secret ... --dry-run=client -o yaml \| kubectl apply -f -`), `kubectl -n gitlab-runner rollout restart deploy/gitlab-runner` |
| Nâng Jenkins / plugin | Theo [6.3](../jenkins/06-van-hanh-va-tu-dong-hoa.md#63-nâng-cấp-an-toàn-quy-trình-chuẩn); luôn kèm `-f values-build-logs.yaml` |
| Node CI hỏng | `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`; autoscaler/EKS thay node. Không mất dữ liệu (không có volume) |
| Đọc log build cũ | [5.14](../jenkins/05-huong-dan-trien-khai.md#đọc-lại-log-đã-lưu) |

## 6. Kết quả kiểm tra khi triển khai

| Kiểm tra | Kết quả (31/10/2026) |
|---|---|
| Terraform | `Apply complete! Resources: 27 added, 0 changed, 0 destroyed` |
| Node CI | `ip-172-31-15-99` (ap-southeast-1c), `workload=ci-agents`, taint `NoSchedule`; 3 node thường vẫn đủ 3 AZ |
| Object Lock | `GOVERNANCE`, 365 ngày |
| Jenkins | `jenkins-0` `3/3 Running`; IRSA `AWS_ROLE_ARN` đúng role |
| Lưu log | Sidecar `seeded 0`, lưu `develop` #1–8, `main` #1–6; `build.xml` đọc lại được (`<result>`, `<duration>`) |
| Artifact | `jenkins/shopping-cart/main/6/artifacts/trivy-report.json` (1,3MB) và `.txt` trong bucket artifacts |
| Agent trên node CI | `shopping-cart-main-7-…` và `shopping-cart-develop-9-…` chạy song song trên `ip-172-31-15-99` |
| Plugin | 127 plugin ghim phiên bản; không có cảnh báo bảo mật |
| GitLab Runner | 19.5.0, `Configuration loaded`, `max_builds=10`; manager trên `ip-172-31-33-92` (node thường); job `runner-…-project-4-…` (`2/2`) trên `ip-172-31-15-99` |

## 7. Sự cố đã gặp và cách xử lý

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `terraform plan` có 4 `update in-place` trên IAM role GitLab Runner, Nexus, Load Balancer Controller | Drift giả: data source có `depends_on = [module.eks]` bị hoãn đọc khi `module.eks` thay đổi | Kiểm tra mọi policy là `-> (known after apply)` rồi apply; về sau bỏ `depends_on` ở các data source đó |
| Pod agent Jenkins vẫn chạy trên node thường sau khi có node CI | `Jenkinsfile` trên GitLab là bản cũ; `podTemplate` trong Jenkinsfile không kế thừa `nodeSelector` của values | Đẩy Jenkinsfile có `nodeSelector` + toleration lên GitLab cho mọi nhánh (bước 3) |
| Sidecar chưa lưu build vừa chạy | Build chưa kết thúc (sidecar chỉ lưu build đã xong), hoặc chưa tới chu kỳ quét 120 giây | Chờ build xong và tối đa 2 phút |
| Bucket artifacts trống sau build | Build fail trước stage `archiveArtifacts` (Trivy) | Không phải lỗi S3; kiểm tra log build |
| `git pull` báo `Need to specify how to reconcile divergent branches` / `You have unstaged changes` | Có thay đổi chưa commit (ví dụ `.terraform.lock.hcl` sau `terraform init`) hoặc chưa đặt cách pull | Commit lock file; `git config pull.rebase true` |
| Lệnh git chạy nhầm repo (`Jenkinsfile: No such file`, `'gitlab' does not appear to be a git repository`) | Đứng ở thư mục `terraform-eks` thay vì `shopping-cart` | `cd` sang repo app; kiểm tra `git remote -v` |
| Runner cảnh báo `Long polling issues … request_concurrency=1` | Mặc định 1 request đồng thời tới GitLab | `request_concurrency = 4` trong `[[runners]]` |
| Pod agent `Pending`, event `didn't match Pod's node affinity/selector` / `untolerated taint` | Chưa có node CI, hoặc pod có `nodeSelector` nhưng thiếu toleration | `kubectl get nodes -L workload`; kiểm tra cả `nodeSelector` và toleration trong `podTemplate` |
| Pod agent `ContainerCreating` vài phút | Node CI mới phải kéo image | Bình thường cho build đầu tiên trên node mới |
