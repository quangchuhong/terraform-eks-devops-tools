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

## 5.12. Artifact trên S3 và node group riêng cho CI agent

### Thành phần

| Thành phần | Cấu hình | File |
|---|---|---|
| Bucket `jenkins-609320954321-artifacts` | SSE-KMS (key riêng, xoay vòng hằng năm), chặn public, versioning, chỉ cho truy cập qua TLS; lifecycle: Standard-IA sau 30 ngày, Glacier Instant Retrieval sau 90 ngày, xoá sau `jenkins_artifacts_retention_days` (mặc định 400 ngày, > 12 tháng) | `jenkins-storage.tf` |
| IAM role `eks-cluster-ver1-jenkins-artifacts` (IRSA) | Chỉ service account `jenkins/jenkins` được assume; chỉ có quyền trên bucket và KMS key đó | `jenkins-storage.tf` |
| Plugin `artifact-manager-s3` + JCasC `artifact-s3` | `archiveArtifacts`/`stash` lưu trên S3. Controller ký URL, agent tải lên/xuống trực tiếp, không đi qua controller | `helm-install/jenkins/jenkins/values.yaml` |
| Node group `ci_agents` | `m6i.xlarge`/`m5.xlarge`, ON_DEMAND (đổi `ci_agent_capacity_type = "SPOT"` để giảm chi phí), 1–10 node, ổ gốc 100 GiB, label và taint `workload=ci-agents:NoSchedule` | `eks.tf`, `variables.tf` |
| Pod agent của Jenkins | `nodeSelector: workload=ci-agents` + toleration (template mặc định trong values và `podTemplate` trong Jenkinsfile) | `values.yaml`, `Jenkinsfile` của app |

### Thứ tự áp dụng

1. **Terraform trước**: tạo node group, bucket và IAM role.
   ```bash
   git pull origin main
   terraform plan
   terraform apply
   kubectl get nodes -L workload
   ```
   Plan mong đợi: **thêm** node group `ci_agents`, KMS key/alias, bucket và các cấu hình đi kèm, IAM role/policy; **không** đổi node group `eks_nodes`. Phải có ít nhất 1 node mang `workload=ci-agents`.
2. **Jenkins**: chạy `helm upgrade` (thêm plugin, IRSA, JCasC S3, agent mặc định lên node CI).
   ```bash
   helm upgrade --install jenkins ./helm-install/jenkins/jenkins -n jenkins --timeout 15m
   kubectl -n jenkins wait --for=condition=Ready pod/jenkins-0 --timeout=15m
   ```
   Nếu init container báo `PluginDependencyException`, xử lý như mục 5.8. Khi chạy ổn, ghim `artifact-manager-s3` và các dependency mới bằng `security-audit/run.sh plugins.groovy`.
3. **Jenkinsfile của app** (đã có `nodeSelector` + toleration): push lên GitLab rồi chạy build. Nếu đổi Jenkinsfile trước khi có node group, pod agent sẽ `Pending` mãi.

### Kiểm tra

```bash
kubectl -n jenkins get pods -o wide
kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'env | grep -E "AWS_ROLE_ARN|AWS_WEB_IDENTITY_TOKEN_FILE"'
aws s3 ls s3://$(terraform output -raw jenkins_artifacts_bucket)/jenkins/ --recursive | head
```

- Pod agent `shopping-cart-*` phải chạy trên node có `workload=ci-agents`.
- Controller có biến `AWS_ROLE_ARN` (IRSA đã gắn).
- Sau một build có `archiveArtifacts` (báo cáo Trivy), file xuất hiện dưới `jenkins/` trong bucket. Trên giao diện Jenkins vẫn tải artifact bình thường (qua URL đã ký).

### GitLab Runner dùng chung node group CI

Khi cài GitLab Runner (Kubernetes executor), đặt pod job lên cùng node group:

```toml
[[runners]]
  [runners.kubernetes]
    namespace = "gitlab-runner"
    [runners.kubernetes.node_selector]
      workload = "ci-agents"
    [runners.kubernetes.node_tolerations]
      "workload=ci-agents" = "NoSchedule"
```

Pod của chính GitLab Runner (manager) có thể chạy ở node thường. Chỉ pod **job** cần lên node CI.

## 5.13. Mở rộng volume `JENKINS_HOME` khi gần đầy

`JENKINS_HOME` (PVC `jenkins`, mặc định 20Gi) chứa log build (Console Output), kết quả test và coverage, metadata build, cấu hình job và plugin. Artifact và stash đã chuyển lên S3 ([5.12](#512-artifact-trên-s3-và-node-group-riêng-cho-ci-agent)). Volume vẫn đầy dần theo số job và số build được giữ lại.

### Điều kiện (đã có sẵn)

| Điều kiện | Hiện trạng |
|---|---|
| StorageClass cho phép mở rộng | `gp3` có `allowVolumeExpansion: true` (`ebs-csi-cotroller.tf`; provider kubernetes cũng mặc định `true`) |
| Driver có quyền `ec2:ModifyVolume` | Role `ebs-csi-controller-role` dùng `AmazonEBSCSIDriverPolicy` |
| PVC sửa được qua Helm | Chart tạo PVC `jenkins` độc lập, **không** dùng `volumeClaimTemplates` của StatefulSet, nên đổi `persistence.size` rồi `helm upgrade` là PVC được cập nhật |

Kiểm tra nhanh:

```bash
kubectl get storageclass gp3 -o jsonpath='{.allowVolumeExpansion}{"\n"}'
kubectl -n jenkins get pvc jenkins
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

### Quy trình mở rộng (online, không cần restart pod)

**Bước 1. Snapshot trước khi đổi** (mục [5.9](#59-sao-lưu-và-khôi-phục)):

```bash
VOL=$(kubectl get pv $(kubectl -n jenkins get pvc jenkins -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 create-snapshot --volume-id "$VOL" --description "jenkins-home before resize $(date +%F)" --region ap-southeast-1
```

**Bước 2. Tăng dung lượng.** Sửa `persistence.size` trong `helm-install/jenkins/jenkins/values.yaml` (ví dụ `"20Gi"` → `"50Gi"`), commit, rồi:

```bash
helm upgrade jenkins ./helm-install/jenkins/jenkins -n jenkins -f ./helm-install/jenkins/jenkins/values.yaml
```

Khi cần xử lý gấp, có thể patch trực tiếp PVC, **nhưng phải sửa `values.yaml` ngay sau đó**. Nếu không, lần `helm upgrade` sau sẽ cố đặt lại size nhỏ hơn và bị Kubernetes từ chối (PVC không cho thu nhỏ):

```bash
kubectl -n jenkins patch pvc jenkins -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

**Bước 3. Theo dõi.** EBS CSI tăng kích thước volume EBS, sau đó kubelet mở rộng filesystem ext4 ngay khi pod đang chạy:

```bash
kubectl -n jenkins get pvc jenkins -w
kubectl -n jenkins describe pvc jenkins | tail -10
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
```

Kết quả mong đợi: các event `Resizing` → `VolumeResizeSuccessful` (phía AWS) → `FileSystemResizeSuccessful` (phía node), `CAPACITY` của PVC đổi sang `50Gi`, và `df` hiển thị dung lượng mới. Thường mất từ vài chục giây đến vài phút.

Nếu PVC dừng ở điều kiện `FileSystemResizePending` quá lâu, filesystem sẽ được mở rộng ở lần mount kế tiếp: `kubectl -n jenkins delete pod jenkins-0` (Jenkins gián đoạn khoảng 5 phút).

### Giới hạn cần biết

| Giới hạn | Ý nghĩa với vận hành |
|---|---|
| **Không thu nhỏ được** | Chỉ tăng. Muốn giảm phải tạo volume mới và copy dữ liệu, nên tăng theo từng bậc hợp lý (ví dụ 20 → 50 → 100Gi), không tăng quá tay |
| **6 giờ mới sửa được một lần** trên cùng volume EBS | Sau một lần đổi, volume ở trạng thái `optimizing` và AWS chặn lần sửa tiếp theo trong 6 giờ. Hãy tăng đủ một lần, đừng tăng nhiều lần nhỏ |
| Volume EBS gắn với một AZ | Mở rộng không đổi AZ; vẫn cần node ở AZ đó (`min_size = 3`) |
| IOPS/throughput không tự tăng theo size | gp3 mặc định 3000 IOPS / 125 MiB/s bất kể dung lượng. Nếu nghẽn I/O (UI chậm, load job chậm), tăng qua tham số StorageClass (`iops`, `throughput`, chỉ áp dụng cho volume mới) hoặc `VolumeAttributesClass` (Kubernetes 1.34) cho volume đang chạy; xem [2.5](02-sizing.md) |
| Tối đa 64 TiB | Không phải giới hạn thực tế; nếu `JENKINS_HOME` vượt vài trăm GiB thì cần dọn dữ liệu hoặc tách controller, không phải tiếp tục tăng |

### Phòng ngừa (để ít phải mở rộng)

1. **Cảnh báo sớm:** cảnh báo ở 80% và 90% dựa trên metric của kubelet (cần Prometheus, xem [6.4.4](06-van-hanh-va-tu-dong-hoa.md#644-giám-sát-và-cảnh-báo)):
   ```promql
   kubelet_volume_stats_used_bytes{namespace="jenkins",persistentvolumeclaim="jenkins"}
     / kubelet_volume_stats_capacity_bytes{namespace="jenkins",persistentvolumeclaim="jenkins"} > 0.8
   ```
2. **Giới hạn số build lưu lại:** `buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))` trong Jenkinsfile (repo `shopping-cart` đã có), cộng với global build discarder cho các job không tự khai báo.
3. **Tìm thủ phạm trước khi tăng:**
   ```bash
   kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'du -sh /var/jenkins_home/* 2>/dev/null | sort -h | tail -10'
   kubectl -n jenkins exec jenkins-0 -c jenkins -- sh -c 'du -sh /var/jenkins_home/jobs/*/branches/* 2>/dev/null | sort -h | tail -10'
   ```
   Các thủ phạm hay gặp: nhánh Multibranch đã xoá nhưng job còn (đặt orphaned item strategy), log build rất dài (test in quá nhiều log), thư mục `workspace/` trên controller (không nên có, vì không build trên controller), và `caches/`.
4. **Đưa log build ra ngoài** (S3 hoặc CloudWatch, giai đoạn sau): phần này chiếm nhiều dung lượng nhất sau khi artifact đã lên S3.
