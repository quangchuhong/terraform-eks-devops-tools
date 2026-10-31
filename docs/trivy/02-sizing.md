# 2. Sizing Trivy theo mức tải

[← Mục lục Trivy](README.md)

## 2.1. Nguyên tắc

- **Phần nặng nằm ở client** (pod build): giải nén layer image, đọc file, giữ Java DB. Server chỉ so khớp danh sách gói với DB, nhẹ.
- **Ổ tạm (ephemeral storage) của node CI** là giới hạn hay gặp nhất: image tar + layer giải nén + Java DB (khoảng 3–4 GB) + cache.
- **Mạng**: mỗi pod build mới tải Java DB từ ghcr.io nếu không có cache. Nhiều build song song dễ chậm hoặc bị giới hạn tải.

## 2.2. Ba mức cấu hình

| Hạng mục | Tải thấp (hiện tại) | Tải vừa | Enterprise |
|---|---|---|---|
| Quy mô | < 50 lần quét/ngày | 100–1.000 lần quét/ngày | Hàng nghìn lần quét/ngày, nhiều cụm |
| Server | 1 pod, 200m/512Mi (limit 1 CPU/1Gi), PVC 5Gi | 2–3 pod, mỗi pod 500m–1 CPU / 1–2Gi, **Redis cache** dùng chung (`trivy.cache.redis`) | 3+ pod sau Service, Redis (ElastiCache), DB từ mirror nội bộ |
| Client (container `trivy` trong pod build) | Không đặt request/limit; tải Java DB mỗi lần | request 500m/1Gi, limit 2 CPU/3Gi; `ephemeral-storage` request 6Gi; Java DB từ cache/mirror | Như vừa; Java DB nằm sẵn trong image client nội bộ hoặc volume cache trên node |
| DB | Tải trực tiếp từ ghcr.io | Mirror Trivy DB + Java DB vào registry nội bộ (Nexus/ECR) | Mirror nội bộ, cập nhật theo lịch, môi trường cô lập được |
| Node CI | Ổ gốc 100 GiB | 100–200 GiB | Theo số build song song |

## 2.3. Ví dụ cấu hình

Server (values):

```yaml
replicaCount: 2
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits:   { cpu: 1, memory: 2Gi }
trivy:
  cache:
    redis:
      enabled: true
      url: "rediss://<elasticache-endpoint>:6379"
      ttl: "72h"
      tls: true
  dbRepository: "docker.gitlabonlinecom.click/aquasecurity/trivy-db"   # mirror/proxy nội bộ
```

Client (container trong `podTemplate`):

```groovy
containerTemplate(
  name: 'trivy',
  image: 'aquasec/trivy:0.68.2',
  command: 'cat', ttyEnabled: true,
  resourceRequestCpu: '500m', resourceRequestMemory: '1Gi',
  resourceLimitCpu: '2', resourceLimitMemory: '3Gi',
  resourceRequestEphemeralStorage: '6Gi', resourceLimitEphemeralStorage: '12Gi'
)
```

## 2.4. Theo dõi

| Chỉ số | Ngưỡng | Hành động |
|---|---|---|
| Thời gian stage Trivy | > 5 phút | Cache/mirror Java DB; tăng CPU client |
| Pod build bị Evicted (`ephemeral-storage`) | Có | Đặt request ephemeral-storage; tăng ổ node; chỉ bật scanner cần thiết |
| Lỗi tải DB (`TOOMANYREQUESTS`, timeout ghcr.io) | Có | Mirror nội bộ, `gitHubToken` |
| CPU/memory server | > 70% | Thêm replica + Redis cache |
| Tuổi DB trên server | > 24 giờ | Kiểm tra server tải DB được không |
