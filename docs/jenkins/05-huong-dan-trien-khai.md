# 5. Hướng dẫn cấu hình đã triển khai

[← Mục lục](README.md)

Các bước dưới là đúng trình tự đã dùng để dựng Jenkins trên cụm `eks-cluster-ver1`. Mọi lệnh chạy từ thư mục gốc repo `terraform-eks-devops-tools`.

## 5.1. Điều kiện trước

| Thành phần | Kiểm tra | Do đâu tạo |
|---|---|---|
| Cụm EKS, 3 node ở 3 AZ, ổ gốc 100 GiB | `kubectl get nodes -L topology.kubernetes.io/zone` | Terraform (`eks.tf`, `min_size = 3`, `node_disk_size = 100`) |
| AWS Load Balancer Controller | `kubectl -n kube-system get deploy aws-load-balancer-controller` | Terraform |
| StorageClass `gp3` (mặc định, mã hoá) | `kubectl get sc gp3` | Terraform (`ebs-csi-cotroller.tf`) |
| ALB chung (group `alb-apps`) và bản ghi DNS `jenkins.gitlabonlinecom.click` | `terraform output alb_dns_name` | GitLab Ingress + `dns.tf` (`enable_dns_records = true`) |
| Nexus, SonarQube, GitLab đã chạy | `kubectl get pods -A \| grep -E "nexus\|sonarqube\|gitlab"` | `helm-install/README.md` |

## 5.2. Các file cấu hình

| File | Nội dung |
|---|---|
| `helm-install/jenkins/jenkins/` | Chart `jenkins` 5.8.116 (vendored) |
| `helm-install/jenkins/jenkins/values.yaml` | **Toàn bộ cấu hình**: image, tài nguyên, plugin ghim phiên bản, JCasC, Ingress, Secret mount |
| `helm-install/jenkins/security-audit/run.sh` | Chạy script Groovy trong Jenkins (chỉ đọc), mật khẩu đọc ngay trong pod |
| `helm-install/jenkins/security-audit/audit.groovy` | Báo cáo bảo mật |
| `helm-install/jenkins/security-audit/plugins.groovy` | In danh sách plugin `tên:phiên-bản` để ghim |
| `helm-install/nexus/bootstrap.sh` | Tạo user Nexus `ci-jenkins` và Secret `jenkins/nexus-ci` |
| `helm-install/sonarqube/bootstrap.sh` | Tạo token SonarQube và Secret `jenkins/sonarqube-token`, cùng webhook |
| `removed.tf` | Bỏ `helm_release.jenkins` khỏi state Terraform (Jenkins cài bằng helm CLI, không bằng Terraform) |

## 5.3. Tạo Secret (trước khi cài)

Pod Jenkins mount 3 Secret dưới đây. **Thiếu Secret nào thì pod kẹt ở `ContainerCreating`.**

```bash
./helm-install/nexus/bootstrap.sh
./helm-install/sonarqube/bootstrap.sh
read -r -s -p "GitLab token: " GL_TOKEN; echo
kubectl -n jenkins create secret generic gitlab-ci --from-literal=username=oauth2 --from-literal=token="$GL_TOKEN"
unset GL_TOKEN
```

- `nexus-ci` và `sonarqube-token` do script tạo; giá trị không in ra màn hình.
- Token GitLab là **group access token của group `devops`**: role Maintainer, scope `read_repository` và `write_repository`. Token tạo ở group khác sẽ không đọc được project trong `devops`.

## 5.4. Cài đặt

```bash
helm upgrade --install jenkins ./helm-install/jenkins/jenkins -n jenkins --create-namespace --timeout 15m
kubectl -n jenkins wait --for=condition=Ready pod/jenkins-0 --timeout=15m
kubectl -n jenkins get ingress
```

- Lần khởi động nào cũng mất khoảng **4–5 phút** để init container cài 124 plugin. Cảnh báo `Startup probe failed` trong lúc này là bình thường.
- Ingress phải có ADDRESS trùng với ALB của GitLab (`k8s-albapps-...`).
- Cột `APP VERSION 2.528.3` trong `helm history` là phiên bản mặc định của chart. Phiên bản chạy thật là `2.580.2` (ghi đè bằng `controller.image.tag`).

## 5.5. Đăng nhập và đổi mật khẩu admin

```bash
kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d | pbcopy
```

Lệnh này chép mật khẩu vào clipboard trên macOS. Không dán mật khẩu vào chat hay ticket.

Đổi mật khẩu: JCasC tạo user `admin` từ Secret, nên phải **đổi trong Secret**. Đổi trên giao diện sẽ bị JCasC ghi đè.

```bash
NEWPW=$(openssl rand -base64 24 | tr -d '/+=')
kubectl -n jenkins patch secret jenkins -p "{\"stringData\":{\"jenkins-admin-password\":\"$NEWPW\"}}"
kubectl -n jenkins delete pod jenkins-0
echo "$NEWPW"
```

`helm upgrade` sau này vẫn giữ mật khẩu mới (chart chỉ tạo Secret khi chưa có).

## 5.6. Kiểm tra sau khi cài

```bash
./helm-install/jenkins/security-audit/run.sh
```

Kết quả mong đợi:

```
Jenkins version                    2.580.2
Executors on built-in              0
Sign-up allowed                    false
Anonymous can READ                 false
CSRF crumb issuer                  hudson.security.csrf.DefaultCrumbIssuer
System credentials                 [nexus-creds (...), docker-user-internal (...), sonarqube-token (...), gitlab-token-dev-group (...)]
Installed plugins                  124
Core warnings                      []
Plugin warnings                    []
```

## 5.7. Tạo job Multibranch Pipeline

1. **New Item** → nhập tên (ví dụ `shopping-cart`) → **Multibranch Pipeline**.
2. **Branch Sources → Git**: URL `http://gitlab.gitlabonlinecom.click/devops/ci-cd/<repo>.git`, Credentials `gitlab-token-dev-group`.
3. **Build Configuration**: by Jenkinsfile, Script Path `Jenkinsfile`.
4. **Scan Multibranch Pipeline Triggers**: *Periodically if not otherwise run*, 5 minutes.

Chi tiết pipeline Maven mẫu: [ci-cd-maven-java-ver1/docs/CI-pipeline.md](https://github.com/quangchuhong/ci-cd-maven-java-ver1/blob/main/docs/CI-pipeline.md).

## 5.8. Nâng cấp

### Nâng cấp Jenkins core

1. Lấy bản LTS mới nhất: `curl -sL https://updates.jenkins.io/stable/latestCore.txt`.
2. Snapshot volume trước khi nâng cấp (mục 5.9).
3. Sửa `controller.image.tag` thành `<phiên-bản>-jdk21`, rồi `helm upgrade`.
4. Chạy `security-audit/run.sh` để kiểm tra lại.

### Nâng cấp plugin

Toàn bộ plugin đang ghim phiên bản. Quy trình:

1. Đổi **22 plugin chính** trong `controller.installPlugins` về `:latest`, xoá phần `# Dependencies`, rồi tạm đặt `installLatestPlugins: true`.
2. `helm upgrade`, chờ pod Ready, chạy `security-audit/run.sh`. Kết quả phải có `Plugin warnings []` và `Core warnings []`.
3. Lấy danh sách phiên bản vừa cài: `./helm-install/jenkins/security-audit/run.sh plugins.groovy`.
4. Ghim lại toàn bộ danh sách vào values và trả `installLatestPlugins: false`. Commit.

**Không ghim riêng lẻ một plugin cũ hơn mức dependency yêu cầu.** Ví dụ ghim `configuration-as-code` 2031 trong khi `git-client` 6.6.1 cần bản 2036 sẽ làm init container lỗi `PluginDependencyException`.

### Thêm plugin

Thêm `tên:latest` vào `installPlugins`, rồi làm như bước nâng cấp để ghim phiên bản. Plugin cài tay trên giao diện sẽ bị gỡ ở lần khởi động sau (`overwritePlugins: true`).

## 5.9. Sao lưu và khôi phục

`JENKINS_HOME` nằm trên volume EBS. StorageClass `gp3` dùng `reclaimPolicy: Delete` (mặc định), nên **`helm uninstall` rồi xoá PVC sẽ xoá luôn dữ liệu**. Hãy snapshot trước mọi thao tác lớn.

```bash
VOL=$(kubectl get pv $(kubectl -n jenkins get pvc jenkins -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 create-snapshot --volume-id "$VOL" --description "jenkins-home $(date +%F)" --region ap-southeast-1 \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=app,Value=jenkins}]'
```

Nên tự động hoá việc này bằng **AWS Backup** hoặc **Data Lifecycle Manager** (snapshot hằng ngày, giữ 7–30 bản).

**Khôi phục:** tạo volume từ snapshot **trong cùng AZ** với node, tạo PV/PVC trỏ tới volume đó, rồi cài Jenkins với `persistence.existingClaim`. Cấu hình hệ thống, plugin và credentials đã nằm trong values, JCasC và Secret, nên snapshot chủ yếu để giữ job, lịch sử build và artifact.

## 5.10. Sự cố đã gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Init:CrashLoopBackOff`, log init: `PluginDependencyException … configuration-as-code:2036 … older version defined on the top level` | Ghim một plugin cũ hơn bản dependency yêu cầu | Đổi tất cả về `latest`, cài xong rồi ghim lại cả bộ |
| Pod `ContainerCreating` sau khi thêm Secret | Secret trong `additionalExistingSecrets` chưa tồn tại | Tạo Secret (mục 5.3) |
| Build đứng ở `is offline`; log `jnlp`: `UnsupportedClassVersionError … class file version 65.0` | Agent `jnlp` JDK 17, controller cần Java 21 | `inbound-agent:…-jdk21` (cả `agent.image.tag` và Jenkinsfile) |
| Pod agent **Evicted** (`ephemeral-storage`) | Ổ gốc node 20 GiB | Ổ gốc 100 GiB (`node_disk_size`) |
| `jenkins-0` `Pending`: `volume node affinity conflict` | Volume EBS ở AZ không còn node | `min_size = 3` (1 node mỗi AZ); tạm thời tăng `desiredSize` bằng `aws eks update-nodegroup-config` |
| Đổi mật khẩu trên giao diện, khởi động lại thì mất | JCasC ghi đè user `admin` từ Secret | Đổi trong Secret `jenkins` (mục 5.5) |
| `run.sh plugins.groovy`: `UnsupportedOperationException` | Sắp xếp trực tiếp trên danh sách chỉ đọc | Đã sửa: dùng `sort(false)` |
| Credential mới không có hiệu lực | Secret đổi nhưng JCasC chưa nạp lại | `kubectl -n jenkins delete pod jenkins-0` |

## 5.11. Gỡ cài đặt

```bash
helm -n jenkins uninstall jenkins
```

PVC `jenkins` vẫn còn sau lệnh trên. Chỉ xoá PVC (`kubectl -n jenkins delete pvc jenkins`) sau khi đã snapshot, vì xoá PVC sẽ xoá luôn volume EBS.
