# 2. Sizing Jenkins theo mức tải

[← Mục lục](README.md)

## 2.1. Nguyên tắc

- **Controller không chạy build** (`numExecutors: 0`). Tài nguyên của controller phụ thuộc vào **số job, số build lưu lại, số người dùng và số build chạy đồng thời**, không phụ thuộc vào độ nặng của từng build.
- **Tải build nằm ở agent**: mỗi build là một pod, nên năng lực build là năng lực của node group cộng với Cluster Autoscaler.
- **Chiến lược scale được chọn: scale dọc + giảm tải cho controller** ([mục 2.5](#25-scale-khi-chạy-nhiều-job-đồng-thời)). Controller Jenkins OSS hoạt động ổn với heap tối đa khoảng 8–16 GB. Chỉ khi đã giảm tải mà vẫn vượt mức đó mới tách thêm controller.
- **Heap JVM khoảng 50–75% giới hạn RAM của container.** Phần còn lại dành cho metaspace, thread và bộ nhớ ngoài heap. Có thể dùng `-XX:MaxRAMPercentage=70` thay cho `-Xmx` cố định.
- **Ổ đĩa `JENKINS_HOME` tăng theo số build lưu lại**, nên luôn đặt build discarder (pipeline `shopping-cart` giữ 20 build).

## 2.2. Ba mức cấu hình

| | **Tải thấp** (lab / team nhỏ) | **Tải vừa** (nhiều team) | **Enterprise** (tải lớn) |
|---|---|---|---|
| Quy mô | < 20 người, < 50 job, < 100 build/ngày, ≤ 5 build đồng thời | 20–200 người, 50–500 job, 100–1.000 build/ngày, 10–30 build đồng thời | > 200 người, > 500 job, > 1.000 build/ngày, 50+ build đồng thời |
| Số controller | 1 | 1 | 1 controller đã scale dọc và giảm tải (mục 2.5). Chỉ tách thêm (theo khối nghiệp vụ) khi vượt giới hạn; HA active-active cần CloudBees CI |
| CPU controller (request / limit) | 0.5 / 2 | 2 / 4 | 4 / 8 mỗi controller |
| RAM controller (request / limit) | 1Gi / 4Gi | 4Gi / 8Gi | 8Gi / 16Gi mỗi controller |
| Heap (`-Xmx`) | 1–2 GB | 4–6 GB | 8–12 GB |
| GC | Mặc định (G1) | G1, `-XX:+UseStringDeduplication` | G1 + theo dõi GC log, tune theo thực tế |
| `JENKINS_HOME` | 20 GiB gp3 | 50–100 GiB gp3 (3000 IOPS) | 200+ GiB gp3/io2, tăng IOPS và throughput |
| Lưu build | 20–50 build/job | 30 build hoặc 30 ngày | Theo chính sách; artifact lớn đẩy lên Nexus hoặc S3, không giữ trên controller |
| Node cho agent | Dùng chung node group | **Node group riêng** cho agent (có taint), có thể dùng Spot | Nhiều node group/Karpenter theo loại build (CPU, RAM, ARM, GPU); Spot cho build ngắn |
| Giới hạn pod agent | `containerCap` 10 | 30–50, ResourceQuota cho namespace build | Theo quota từng team; namespace riêng cho mỗi controller |
| Cache build | Không (dùng Nexus làm proxy) | Nexus proxy + PVC cache Maven/npm dùng chung (EFS) | Nexus HA + cache theo team, image build dựng sẵn công cụ |
| Sao lưu | Snapshot EBS hằng ngày | Snapshot EBS + JCasC/job trong Git | Snapshot nhiều lần/ngày, sao chép sang Region khác, **tất cả cấu hình là code** |
| Tính sẵn sàng | 1 pod; nếu lỗi thì Kubernetes tạo lại (khoảng 5 phút) | Như trên, kèm PodDisruptionBudget; plugin cài sẵn trong image để khởi động nhanh | Jenkins OSS **không chạy active-active**: node riêng cho controller, QoS Guaranteed, image có sẵn plugin (khởi động khoảng 1 phút), cửa sổ bảo trì, snapshot thường xuyên |
| Giám sát | Log pod | Plugin Prometheus + Grafana, cảnh báo heap/queue | Như trên + log tập trung (CloudWatch/ELK), SLO cho thời gian chờ build |

### Cấu hình hiện tại

Cụm `eks-cluster-ver1` đang ở mức **tải thấp**:

| Hạng mục | Hiện tại |
|---|---|
| Controller | requests 50m/256Mi, limits 2 CPU/4Gi, heap 512m–1024m |
| `JENKINS_HOME` | 20Gi gp3 |
| Node | 3 × t3.xlarge (4 vCPU, 16 GiB), ổ gốc 100 GiB, tự scale 3–10 node, **dùng chung** với GitLab, Nexus, SonarQube |
| Pod agent `shopping-cart` | Khoảng 1.7 CPU / 2.8 GiB request (jnlp 0.2/256Mi, maven 0.5/1Gi, maven17 0.5/1Gi; docker và trivy không đặt request) |

**Nên chỉnh ngay khi tải tăng:**
- Tăng requests của controller lên **0.5 CPU / 1Gi**. Request 50m/256Mi quá thấp: scheduler có thể đặt pod lên node đã chật.
- Tăng heap lên `-Xmx2g` (limit 4Gi vẫn đủ chỗ).
- Đặt resource requests/limits cho container `docker` và `trivy` trong Jenkinsfile. Hiện chưa đặt, nên scheduler không tính đến 3–4 GB ổ đĩa và RAM mà Trivy dùng.

## 2.3. Ví dụ values cho từng mức

**Tải vừa:**

```yaml
controller:
  resources:
    requests: { cpu: "2", memory: "4Gi" }
    limits:   { cpu: "4", memory: "8Gi" }
  javaOpts: "-XX:MaxRAMPercentage=70 -XX:+UseG1GC -XX:+UseStringDeduplication"
  podDisruptionBudget:
    enabled: true
    apiVersion: "policy/v1"   # chart mặc định policy/v1beta1, đã bị gỡ từ Kubernetes 1.25
    maxUnavailable: "0"
persistence:
  size: "100Gi"
agent:
  containerCap: 40
  # Agent chạy trên node group riêng dành cho build
  nodeSelector:
    workload: ci-agents
  yamlTemplate: |
    spec:
      tolerations:
        - key: workload
          operator: Equal
          value: ci-agents
          effect: NoSchedule
```

Với `maxUnavailable: "0"`, PDB chặn mọi lần drain node đang chạy Jenkins, kể cả khi thay node bằng Terraform. Khi bảo trì node, phải tạm gỡ PDB hoặc chấp nhận Jenkins downtime.

**Enterprise:** chia thành nhiều release Helm (ví dụ `jenkins-payments`, `jenkins-core`), mỗi release có namespace, ResourceQuota, node pool và quyền riêng. Plugin được build sẵn vào image riêng (`FROM jenkins/jenkins:<LTS>` + `jenkins-plugin-cli --plugin-file plugins.txt`) để pod khởi động trong vài chục giây thay vì 5 phút.

## 2.4. Theo dõi để biết khi nào cần nâng cấp

| Chỉ số | Ngưỡng cảnh báo | Hành động |
|---|---|---|
| Heap sau GC (old gen) | > 70% liên tục | Tăng heap hoặc RAM, giảm số build lưu lại |
| Hàng đợi build (queue) | Build chờ > 2–5 phút | Tăng `containerCap`, thêm node, kiểm tra pod Pending |
| Pod agent `Pending` | > 1 phút | Thiếu node: kiểm tra Cluster Autoscaler, `max_size`, quota |
| Dung lượng `JENKINS_HOME` | > 80% | Mở rộng PVC (gp3 cho phép mở rộng online), giảm số build lưu lại |
| Thời gian phản hồi giao diện | > 2 giây | Kiểm tra CPU, GC và plugin nặng |

Các lệnh kiểm tra nhanh:

```bash
kubectl -n jenkins top pod jenkins-0
kubectl -n jenkins exec jenkins-0 -c jenkins -- df -h /var/jenkins_home
kubectl -n jenkins get pods | grep -c Pending
```

## 2.5. Scale khi chạy nhiều job đồng thời

### 2.5.1. Vì sao controller chạy bằng StatefulSet, 1 replica

Jenkins controller là ứng dụng **có trạng thái (stateful)** và **chỉ được chạy đúng 1 bản**:

- Toàn bộ trạng thái nằm trên ổ đĩa `JENKINS_HOME`: cấu hình XML, job, lịch sử và log build, hàng đợi, credentials đã mã hoá. Jenkins không dùng database ngoài để chia sẻ trạng thái.
- Jenkins OSS **không có cơ chế cluster**. Hai controller cùng ghi một `JENKINS_HOME` sẽ làm hỏng dữ liệu. Trạng thái đang chạy (hàng đợi, pipeline đang chạy, kết nối tới agent) chỉ nằm trong RAM của một tiến trình.

StatefulSet bảo đảm đúng các điều kiện đó:

| Đặc điểm của StatefulSet | Tác dụng với Jenkins |
|---|---|
| Danh tính cố định (`jenkins-0`) | Luôn là cùng một controller sau mỗi lần khởi động lại |
| Gắn cố định với PVC | Pod mới luôn mount lại đúng volume `JENKINS_HOME` |
| **Không bao giờ có 2 pod cùng danh tính**: pod cũ bị xoá hẳn rồi pod mới mới được tạo | Không có lúc 2 controller cùng ghi một volume. Volume EBS lại chỉ gắn được vào 1 node (`ReadWriteOnce`) |

Deployment với chiến lược mặc định `RollingUpdate` tạo pod mới **trước khi** xoá pod cũ, nên dễ gây tranh chấp volume. **Tăng `replicas` lên 2 không giúp scale**: nó chỉ tạo ra một controller thứ hai có `JENKINS_HOME` riêng, không chung job.

### 2.5.2. Hai tầng scale

```
Nhiều build đồng thời
 ├─ Tầng AGENT  – scale ngang tự động
 │    mỗi build = 1 pod → thiếu tài nguyên thì pod Pending → Karpenter / Cluster Autoscaler thêm node
 │    build xong thì pod bị xoá → node thừa được thu hồi
 └─ Tầng CONTROLLER – scale DỌC + GIẢM TẢI (chiến lược được chọn)
      điều phối, giữ trạng thái pipeline (CPS) trong heap, nhận log từ mọi agent, gọi Kubernetes API
```

Mỗi build **đang chạy** vẫn tiêu tốn tài nguyên trên controller, dù không chạy trên controller:
- trạng thái pipeline (CPS) nằm trong heap;
- log stream được ghi xuống `JENKINS_HOME`;
- mỗi agent giữ một kết nối remoting;
- controller gọi Kubernetes API để tạo và theo dõi pod.

Vì vậy giới hạn số build đồng thời trên một controller là **heap, CPU, IOPS của `JENKINS_HOME` và lượng log**, không phải số node.

### 2.5.3. Chiến lược cho môi trường enterprise (banking)

Chọn **1 controller cho mỗi miền nghiệp vụ hoặc vùng tuân thủ** (ví dụ tách controller phục vụ hệ thống thuộc phạm vi PCI DSS (CDE) khỏi controller phục vụ hệ thống nội bộ). Mỗi controller được **scale dọc** và **giảm tải tối đa**. Lý do chọn cách này cho banking:

- Ít controller thì ít bề mặt tấn công, ít điểm phải audit, ít đợt nâng cấp và dễ chứng minh tuân thủ: mỗi controller là một *system component in scope*.
- Cấu hình tập trung: một bộ plugin ghim, một JCasC, một quy trình change management.
- Tách controller theo **ranh giới tuân thủ** (CDE / non-CDE), không theo số lượng team. Đây là yêu cầu phân tách hệ thống của PCI DSS, không phải để tăng tải.

#### A. Scale dọc controller

| Bậc | Build đồng thời (tham khảo) | CPU (req = limit) | RAM (req = limit) | Heap | `JENKINS_HOME` |
|---|---|---|---|---|---|
| M | ≤ 50 | 4 | 8Gi | 5–6 GB | gp3 200 GiB, 6000 IOPS, 250 MB/s |
| L | 50–150 | 8 | 16Gi | 10–12 GB | gp3 500 GiB, 10000 IOPS, 500 MB/s (hoặc io2) |
| XL | 150–300 | 16 | 32Gi | 16–20 GB | io2 Block Express, IOPS theo đo đạc |

Số build đồng thời chỉ là mức tham khảo: giới hạn thực tế phụ thuộc lượng log và độ phức tạp của pipeline. Cần **load test** (chạy N pipeline mẫu cùng lúc, đo heap, GC, thời gian chờ queue) trước khi chốt bậc.

Cấu hình đi kèm khi scale dọc:

```yaml
controller:
  resources:                       # requests = limits → QoS Guaranteed, không bị evict khi node thiếu RAM
    requests: { cpu: "8", memory: "16Gi" }
    limits:   { cpu: "8", memory: "16Gi" }
  javaOpts: >-
    -XX:InitialRAMPercentage=70 -XX:MaxRAMPercentage=70
    -XX:+UseG1GC -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled
    -XX:+AlwaysPreTouch -XX:+DisableExplicitGC
    -Xlog:gc*:file=/var/jenkins_home/gc.log:time,uptime:filecount=5,filesize=20M
  nodeSelector:
    workload: jenkins-controller   # node riêng cho controller (ví dụ m6i.2xlarge / r6i.2xlarge)
  tolerations:
    - key: workload
      operator: Equal
      value: jenkins-controller
      effect: NoSchedule
  podDisruptionBudget:
    enabled: true
    apiVersion: "policy/v1"
    maxUnavailable: "0"            # chỉ dừng controller trong cửa sổ bảo trì
persistence:
  size: "500Gi"
  storageClass: gp3-jenkins        # StorageClass riêng: gp3 + iops/throughput cao, KMS key của ngân hàng
```

StorageClass riêng cho `JENKINS_HOME`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-jenkins
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true         # mở rộng online khi đầy
reclaimPolicy: Retain              # không mất dữ liệu khi lỡ xoá PVC
parameters:
  type: gp3
  iops: "10000"
  throughput: "500"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:ap-southeast-1:<account>:key/<key-id>   # customer-managed key (PCI DSS 3.6)
```

Lưu ý khi scale dọc:
- **Đặt requests = limits** (QoS Guaranteed). Controller không bị evict và có hiệu năng ổn định. Đây là yêu cầu quan trọng với hệ thống ngân hàng.
- **Heap khoảng 70% RAM.** Phần còn lại dành cho metaspace, thread stack, bộ đệm mạng và page cache của filesystem.
- **Không vượt khoảng 16–20 GB heap**: GC pause dài làm giao diện và agent bị timeout. Đến mức này mà vẫn thiếu thì phải giảm tải thêm (mục B) hoặc tách controller.
- **Node controller dùng On-Demand** (không dùng Spot), đặt cùng AZ với volume; node group của controller có `min_size` ≥ 1 ở **mỗi** AZ có thể chứa volume.

#### B. Giảm tải cho controller

Đây là phần **mang lại hiệu quả lớn nhất**: thường giảm tải controller nhiều hơn so với việc nhân đôi tài nguyên.

| # | Biện pháp | Vì sao | Cấu hình / cách làm |
|---|---|---|---|
| 1 | **0 executor trên controller** | Không build trên controller | `numExecutors: 0` **[Hiện có]** |
| 2 | **Webhook thay cho quét định kỳ** | Quét nhiều repo mỗi 5 phút tốn CPU và gọi GitLab nhiều | `gitlab-branch-source` + webhook GitLab; giảm chu kỳ quét xuống 1–24 giờ chỉ để dự phòng |
| 3 | **Lightweight checkout** khi đọc `Jenkinsfile` | Không clone cả repo về controller chỉ để đọc 1 file | Bật mặc định ở Multibranch; kiểm tra trong cấu hình job |
| 4 | **Logic nặng chạy trong `sh`, không chạy trong Groovy** | Mọi bước Groovy (CPS) chạy trên controller và được serialize liên tục | Vòng lặp, parse JSON lớn, xử lý file → làm trong script shell hoặc Python trên agent; Groovy chỉ điều phối |
| 5 | **Shared Library chuẩn hoá** | Tránh mỗi team tự viết Groovy kém hiệu quả | Hàm `mavenPipeline()`, `dockerBuild()`… do platform team tối ưu |
| 6 | **Durability phù hợp từng loại pipeline** | `MAX_SURVIVABILITY` (mặc định) ghi trạng thái xuống đĩa rất thường xuyên | Pipeline CI (build, test): `PERFORMANCE_OPTIMIZED`. Pipeline deploy production: **giữ `MAX_SURVIVABILITY`** để tiếp tục được sau khi controller khởi động lại |
| 7 | **Giảm log** | Log được ghi qua controller xuống `JENKINS_HOME` | `mvn -B -q` hoặc `--no-transfer-progress`, không in toàn bộ output test; đẩy log chi tiết ra file và lưu ở S3 |
| 8 | **Artifact lưu ở S3, không lưu trên controller** | `archiveArtifacts` và `stash` file lớn đi qua controller | Plugin `artifact-manager-s3` (bucket SSE-KMS, chặn public, versioning); jar và image đẩy lên Nexus |
| 9 | **Giới hạn số build lưu lại** | `JENKINS_HOME` nhỏ thì khởi động nhanh, giao diện nhanh | Global build discarder (JCasC) + `buildDiscarder` trong mỗi `Jenkinsfile` **[Hiện có cho shopping-cart]** |
| 10 | **Image controller có sẵn plugin** | Khởi động khoảng 1 phút thay vì 5 phút, không phụ thuộc Internet | [Phần 6.4.1](06-van-hanh-va-tu-dong-hoa.md#641-image-controller-có-sẵn-plugin) |
| 11 | **Bộ plugin tối thiểu** | Mỗi plugin tốn heap và là một bề mặt tấn công | Rà soát hằng quý, gỡ plugin không dùng; ghim phiên bản **[Hiện có]** |
| 12 | **Giới hạn số build đồng thời theo chủ đích** | Tránh một team chiếm hết controller hoặc một môi trường | `containerCap`/`instanceCap` cho cloud và template; ResourceQuota cho namespace build; `disableConcurrentBuilds()` **[Hiện có]**; plugin `lockable-resources` cho deploy |
| 13 | **Giới hạn gọi Kubernetes API** | Nhiều pod agent được tạo cùng lúc | `maxRequestsPerHost` của cloud, `waitForPodSec` hợp lý |
| 14 | **Không chạy công cụ nặng trên controller** | Sonar, Trivy, test… chạy trong pod agent | Đã làm trong pipeline **[Hiện có]** |

Ví dụ cấu hình:

```groovy
// Jenkinsfile của pipeline CI
properties([
  durabilityHint('PERFORMANCE_OPTIMIZED'),
  disableConcurrentBuilds(),
  buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
])
```

```yaml
# Lưu artifact trên S3 (plugin artifact-manager-s3 + aws-credentials hoặc IRSA)
controller:
  JCasC:
    configScripts:
      artifact-s3: |
        unclassified:
          artifactManager:
            artifactManagerFactories:
              - jclouds:
                  provider: "s3"
        aws:
          awsCredentials:
            region: "ap-southeast-1"
          s3:
            container: "bank-jenkins-artifacts"
            prefix: "jenkins/"
```

Tên các khoá JCasC của `artifact-manager-s3` có thể khác nhau giữa các phiên bản plugin; kiểm tra trang `/manage/configuration-as-code/reference`. Controller nên dùng **IRSA** (service account gắn IAM role chỉ có quyền trên bucket đó), không dùng access key.

#### C. Tầng agent cho tải lớn

| Biện pháp | Cấu hình |
|---|---|
| Node group (hoặc Karpenter NodePool) **riêng cho agent**, có taint | Build không ảnh hưởng controller và các app khác (GitLab, Nexus) |
| **Karpenter** | Tạo node khoảng 1 phút, chọn đúng loại máy; Spot cho build CI, On-Demand cho pipeline deploy production |
| **Requests/limits cho mọi container**, kể cả `ephemeral-storage` | Xếp pod chính xác, tránh Evicted (đã gặp với Trivy) |
| **Cache dependency** | Nexus proxy (Maven, npm, PyPI, Docker); image build có sẵn công cụ |
| **ResourceQuota** cho namespace build | Giới hạn tổng tài nguyên của build, bảo vệ cụm |
| **Tách namespace build** theo vùng tuân thủ | Pod build cho hệ thống CDE chạy ở namespace hoặc node riêng, có NetworkPolicy riêng |

#### D. Khi nào mới tách thêm controller

Chỉ tách khi đã áp dụng hết A, B, C mà vẫn gặp **một trong các dấu hiệu** sau:
- heap sau GC > 70% kéo dài ở bậc XL;
- GC pause > 1 giây thường xuyên;
- giao diện chậm, hoặc hàng đợi dài dù agent còn trống;
- thời gian khởi động hay sao lưu vượt RTO đã cam kết;
- **yêu cầu tuân thủ** cần tách (CDE / non-CDE, mỗi đơn vị có quyền quản trị riêng).

Khi tách, giữ chung Shared Library, JCasC dùng chung và bộ plugin ghim; mỗi controller là một release Helm riêng ([phần 6.4.8](06-van-hanh-va-tu-dong-hoa.md#648-nhiều-controller)).

### 2.5.4. Tính sẵn sàng khi chỉ có 1 controller

| Tình huống | Ảnh hưởng | Giảm thiểu |
|---|---|---|
| Controller khởi động lại (nâng cấp, drain node) | Giao diện không truy cập được khoảng 1–5 phút | Image có sẵn plugin; cửa sổ bảo trì; *quiet down* trước khi dừng; PDB chặn drain ngoài cửa sổ bảo trì |
| Pipeline đang chạy khi controller khởi động lại | Pipeline `MAX_SURVIVABILITY` **tự chạy tiếp** nếu pod agent còn sống; `PERFORMANCE_OPTIMIZED` có thể phải chạy lại | Dùng `MAX_SURVIVABILITY` cho pipeline deploy production |
| Mất node hoặc AZ | Pod chờ node ở đúng AZ của volume | Mỗi AZ có node dự phòng cho controller; RTO theo snapshot nếu mất cả AZ |
| Mất `JENKINS_HOME` | Mất lịch sử build (cấu hình vẫn còn trong Git) | Snapshot (DLM) + sao chép sang Region khác; thử khôi phục hằng tháng |

HA active-active thật sự chỉ có ở bản thương mại (CloudBees CI). Với Jenkins OSS, mục tiêu là **khôi phục nhanh và không mất cấu hình**, không phải không bao giờ có downtime.
