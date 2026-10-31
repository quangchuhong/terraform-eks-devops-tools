# 2. Sizing GitLab theo mức tải

[← Mục lục GitLab](README.md)

## 2.1. Nguyên tắc

- **Đo tải bằng request/giây (RPS), không chỉ bằng số user.** GitLab tính sizing theo RPS: khoảng 20 user trên 1 RPS là mức thường gặp, nhưng CI nhiều (Jenkins quét Multibranch, Runner clone liên tục) có thể làm RPS tăng gấp nhiều lần so với số người.
- **Mỗi thành phần scale khác nhau:**

| Thành phần | Cách scale | Ghi chú |
|---|---|---|
| webservice, sidekiq, registry, gitlab-shell, kas | **Ngang** (HPA thêm pod, Cluster Autoscaler thêm node) | Không trạng thái |
| **Gitaly** | **Dọc** (CPU, RAM, IOPS của 1 pod) hoặc **chia shard** (nhiều Gitaly, mỗi cái giữ một phần repo) | Có trạng thái; chart không hỗ trợ Gitaly Cluster (Praefect) trong Kubernetes |
| RDS PostgreSQL | Dọc (instance class), thêm read replica | Multi-AZ cho sẵn sàng |
| ElastiCache Redis | Dọc; tách cache và hàng đợi khi lớn | Bật replica + failover |
| S3 | Không cần | Chỉ lo lifecycle và chi phí |

- **Gitaly và database là nút thắt đầu tiên** khi tải tăng, không phải webservice.
- Số liệu dưới đây là điểm xuất phát. Khi thiết kế môi trường thật, đối chiếu với **GitLab Reference Architectures** (bản *Cloud Native Hybrid* tương ứng RPS) và đo tải thực tế.

## 2.2. Ba mức cấu hình

| Hạng mục | Tải thấp (hiện tại) | Tải vừa | Enterprise (banking) |
|---|---|---|---|
| Quy mô | ≤ 100 user, ≤ 5 RPS, vài chục repo | 100–1.000 user, ~20 RPS | 1.000–5.000+ user, 40–100 RPS, yêu cầu HA/DR |
| Node cho GitLab | Dùng chung `eks_nodes` (3 × t3.xlarge) với các tool khác | Node group riêng cho GitLab (3–6 × m7i.xlarge/2xlarge) | Node group webservice (c7i.4xlarge), node group sidekiq (m7i.xlarge), node group hỗ trợ |
| webservice | 2 pod (HPA 2–10), request 300m / 2.5Gi | 3–6 pod, mỗi pod 2–4 vCPU / 4–6 GiB, 4 Puma worker | 6–15+ pod, mỗi pod 4 vCPU / 6–8 GiB |
| sidekiq | 1–3 pod (HPA), request 900m / 2Gi | 2–6 pod | Tách hàng đợi: nhóm `urgent` và nhóm còn lại, mỗi nhóm có HPA riêng |
| Gitaly | 1 pod, PVC gp3 50Gi (3000 IOPS) | 1 pod trên node riêng 4 vCPU / 16 GiB, PVC 200–500Gi gp3 (6000+ IOPS) | **Gitaly ngoài Kubernetes** trên EC2 (Gitaly Cluster/Praefect hoặc nhiều shard), io2/gp3 IOPS cao |
| RDS | `db.t4g.medium`, 1 AZ, 50–200 GB | `db.m7g.large`, **Multi-AZ** | `db.r7g.xlarge`+, Multi-AZ, read replica (database load balancing) |
| Redis | `cache.t4g.small`, 1 node | `cache.m7g.large`, 2 node, failover tự động | Hai cụm: cache và hàng đợi/persistent, mỗi cụm có replica |
| Sẵn sàng | Mất Gitaly/RDS là dừng dịch vụ | Chịu được mất 1 node và failover RDS/Redis | Chịu được mất 1 AZ; DR sang region khác (Geo, cần Premium) |

### Cấu hình hiện tại

| Thành phần | Thực tế (sau khi cài) |
|---|---|
| Pod | `webservice` ×2 (2/2), `sidekiq` ×3, `gitaly-0`, `gitlab-shell` ×2, `registry` ×2, `kas` ×2, `toolbox`, `gitlab-exporter` |
| Node | Dùng chung 3 node `t3.xlarge` (4 vCPU, 16 GiB) với Jenkins controller, Nexus, SonarQube, Trivy |
| Đánh giá | Đủ cho lab và một team nhỏ. Khi webservice khởi động, HPA ghi nhận CPU gần 1 core/pod (Puma warm-up) là bình thường |

## 2.3. Ví dụ values cho từng mức

Đặt các khoá này trong `helm-chart/gitlab-values.yaml` (phần `gitlab:`), rồi `terraform apply`.

**Tải vừa:**

```yaml
gitlab:
  webservice:
    minReplicas: 3
    maxReplicas: 8
    workerProcesses: 4
    resources:
      requests: { cpu: 2, memory: 4Gi }
      limits:   { memory: 6Gi }
    nodeSelector: { workload: gitlab }
  sidekiq:
    minReplicas: 2
    maxReplicas: 6
    resources:
      requests: { cpu: 1, memory: 2Gi }
      limits:   { memory: 4Gi }
    nodeSelector: { workload: gitlab }
  gitaly:
    persistence:
      storageClass: gp3-gitaly        # gp3 với iops/throughput cao hơn mặc định
      size: 300Gi                     # chỉ có tác dụng khi tạo mới, xem 2.4
    resources:
      requests: { cpu: 2, memory: 8Gi }
      limits:   { memory: 12Gi }
    nodeSelector: { workload: gitlab }
```

StorageClass riêng cho Gitaly (Terraform hoặc manifest):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-gitaly
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
allowVolumeExpansion: true
reclaimPolicy: Retain               # xoá PVC không xoá repo
volumeBindingMode: WaitForFirstConsumer
```

**Enterprise:** tách hàng đợi Sidekiq thành nhiều nhóm pod:

```yaml
gitlab:
  sidekiq:
    pods:
      - name: urgent
        queueSelector: true
        queues: "urgency=high"
        minReplicas: 2
        maxReplicas: 10
      - name: catchall
        queueSelector: true
        queues: "urgency!=high"
        minReplicas: 2
        maxReplicas: 10
```

Gitaly ngoài cụm: tắt `gitlab.gitaly.enabled`, khai báo `global.gitaly.external` trỏ tới các node Gitaly/Praefect trên EC2 (cài bằng Linux package), dùng chung `gitlab-gitaly-secret`.

## 2.4. Mở rộng ổ Gitaly khi gần đầy

PVC của Gitaly do `volumeClaimTemplates` của StatefulSet tạo (`repo-data-gitlab-gitaly-0`). Kubernetes **không cho sửa `volumeClaimTemplates`**, nên đổi `persistence.size` trong values rồi `helm upgrade` sẽ lỗi hoặc không có tác dụng. Cách làm đúng là sửa trực tiếp PVC (StorageClass `gp3` đã cho phép mở rộng online):

```bash
kubectl -n gitlab get pvc
kubectl -n gitlab exec gitlab-gitaly-0 -- df -h /home/git/repositories
VOL=$(kubectl get pv $(kubectl -n gitlab get pvc repo-data-gitlab-gitaly-0 -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 create-snapshot --volume-id "$VOL" --description "gitaly before resize $(date +%F)" --region ap-southeast-1
kubectl -n gitlab patch pvc repo-data-gitlab-gitaly-0 -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
kubectl -n gitlab get pvc repo-data-gitlab-gitaly-0 -w
kubectl -n gitlab exec gitlab-gitaly-0 -- df -h /home/git/repositories
```

Giống Jenkins ([5.13](../jenkins/05-huong-dan-trien-khai.md#513-mở-rộng-volume-jenkins_home-khi-gần-đầy)): chỉ tăng được, mỗi volume EBS 6 giờ mới sửa được một lần, snapshot trước khi sửa. Không cần sửa values: PVC đã tạo không còn đọc lại `persistence.size`.

## 2.5. Theo dõi để biết khi nào cần nâng cấp

| Chỉ số | Ngưỡng cảnh báo gợi ý | Hành động |
|---|---|---|
| CPU webservice (HPA) | Luôn ở `maxReplicas` | Tăng `maxReplicas`, thêm node |
| Độ trễ trang (p95), lỗi 5xx trên ALB | p95 > 2 giây, 5xx > 1% | Xem Puma queue, DB, Gitaly |
| Hàng đợi Sidekiq (độ trễ job) | > 1 phút kéo dài | Thêm pod sidekiq, tách hàng đợi |
| CPU Gitaly | > 70% kéo dài | Tăng CPU/RAM Gitaly; xem repo lớn, `git gc` |
| IOPS/throughput EBS Gitaly | Chạm giới hạn gp3 | Tăng `iops`/`throughput` (VolumeAttributesClass) |
| Dung lượng PVC Gitaly | > 80% | Mở rộng PVC (2.4), dọn repo |
| RDS: CPU, connections, FreeStorageSpace | CPU > 70%, storage < 20% | Nâng instance, kiểm tra autoscaling storage |
| Redis: memory, evictions | Memory > 75% hoặc có eviction | Nâng node type, tách cache/hàng đợi |
| S3 (`registry`, `artifacts`) | Tăng nhanh | Cleanup policy registry, artifact expiry (6.4) |

Metric lấy từ `gitlab-exporter` (Prometheus, khi cài), CloudWatch (RDS, ElastiCache, ALB, EBS) và `kubectl top`.

## 2.6. Tính sẵn sàng của cấu hình hiện tại

| Thành phần | Điểm lỗi đơn | Ảnh hưởng khi hỏng | Cách giảm |
|---|---|---|---|
| Gitaly (1 pod, EBS 1 AZ) | Có | Không clone/push, không xem code. Pod tự chạy lại trên node cùng AZ (vài phút) | Snapshot EBS định kỳ; enterprise: Gitaly Cluster ngoài Kubernetes |
| RDS (1 AZ) | Có | GitLab dừng hoàn toàn | **Multi-AZ** (failover khoảng 1–2 phút) |
| ElastiCache (1 node) | Có | Mất session, job đang chờ; GitLab lỗi tới khi Redis lên lại | 2 node + `automatic_failover_enabled` |
| webservice, sidekiq, registry, shell, kas | Không (≥ 2 pod) | — | Đặt `PodDisruptionBudget` và trải pod qua các AZ |
| ALB | Không (đa AZ) | — | — |

Với lab, chấp nhận các điểm lỗi đơn trên. Với production banking, tối thiểu phải có RDS Multi-AZ, Redis failover, sao lưu đã kiểm tra khôi phục, và kế hoạch cho Gitaly (xem [6.5](06-van-hanh-va-tu-dong-hoa.md#65-sao-lưu-và-khôi-phục)).
