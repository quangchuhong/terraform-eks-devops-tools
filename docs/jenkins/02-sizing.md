# 2. Sizing Jenkins theo mức tải

[← Mục lục](README.md)

## 2.1. Nguyên tắc

- **Controller không chạy build** (`numExecutors: 0`). Tài nguyên của controller phụ thuộc vào **số job, số build lưu lại, số người dùng và số build chạy đồng thời**, không phụ thuộc vào độ nặng của từng build.
- **Tải build nằm ở agent**: mỗi build là một pod, nên năng lực build là năng lực của node group cộng với Cluster Autoscaler.
- **Không tăng heap vô hạn.** Một controller Jenkins OSS hoạt động ổn với heap tối đa khoảng 8–16 GB. Khi vượt mức đó, nên **tách thành nhiều controller** (theo team hoặc sản phẩm) thay vì tăng tiếp.
- **Heap JVM khoảng 50–75% giới hạn RAM của container.** Phần còn lại dành cho metaspace, thread và bộ nhớ ngoài heap. Có thể dùng `-XX:MaxRAMPercentage=70` thay cho `-Xmx` cố định.
- **Ổ đĩa `JENKINS_HOME` tăng theo số build lưu lại**, nên luôn đặt build discarder (pipeline `shopping-cart` giữ 20 build).

## 2.2. Ba mức cấu hình

| | **Tải thấp** (lab / team nhỏ) | **Tải vừa** (nhiều team) | **Enterprise** (tải lớn) |
|---|---|---|---|
| Quy mô | < 20 người, < 50 job, < 100 build/ngày, ≤ 5 build đồng thời | 20–200 người, 50–500 job, 100–1.000 build/ngày, 10–30 build đồng thời | > 200 người, > 500 job, > 1.000 build/ngày, 50+ build đồng thời |
| Số controller | 1 | 1 (hoặc 1 mỗi khối lớn) | **Nhiều controller** theo team/sản phẩm, có thể dùng CloudBees CI hoặc Operations Center |
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
| Tính sẵn sàng | 1 pod; nếu lỗi thì Kubernetes tạo lại (khoảng 5 phút) | Như trên, kèm PodDisruptionBudget; plugin cài sẵn trong image để khởi động nhanh | Jenkins OSS **không chạy active-active**. Dùng nhiều controller để giảm ảnh hưởng, hoặc CloudBees CI (HA) |
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
