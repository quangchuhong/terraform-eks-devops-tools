# 1. Kiến trúc Nexus và các tuỳ chọn cấu hình

[← Mục lục Nexus](README.md)

## 1.1. Tổng quan

```
 Người dùng / máy build ngoài cụm                       Pod build trong cụm (Jenkins agent, GitLab job)
        │ HTTP                                                     │ http://nexus.nexus.svc.cluster.local:8081
        ▼                                                          │ docker-internal / docker.gitlabonlinecom.click
 ALB alb-apps ── nexus.            → :8081 (giao diện, Maven, npm, PyPI, NuGet, apt, yum, raw, conan...)
              ── docker-internal.  → :8000 (docker-hosted, push)
              ── docker.           → :8001 (docker-group, pull)
              ── docker-proxy.     → :8002 (docker-proxy, Docker Hub)
                     │
┌────────────────────┼─────────────── namespace nexus (node thường) ─────────────────────────────┐
│                    ▼                                                                            │
│   Deployment nexus (1 pod, strategy Recreate)                                                   │
│     sonatype/nexus3:3.85.0, uid 200, heap 2G + direct 1.5G, request 1 CPU / 4Gi                │
│     init container fix-permissions (chown /nexus-data)                                          │
│     /nexus-data  ── PVC nexus-data 20Gi (EBS gp3, mã hoá)                                       │
│        ├── db/        H2 (cấu hình, repo, user, metadata component)                             │
│        ├── blobs/     blob store "default" (file artifact, layer image)                         │
│        └── log/, etc/, keystores/ ...                                                           │
│   Service nexus (:8081), nexus-docker (:8000/8001/8002)                                         │
└───────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                │ proxy (tải lần đầu rồi cache)
                                                ▼
        Maven Central, PyPI, npmjs, Docker Hub, ghcr.io, quay.io, mcr, kho apt/yum, ConanCenter...
```

### Ba loại repository

| Loại | Vai trò | Ví dụ đang có |
|---|---|---|
| **proxy** | Cache một kho bên ngoài. Lần đầu tải từ Internet, các lần sau lấy từ Nexus | `maven-central`, `docker-proxy` (Docker Hub), `npm-proxy`, `pypi-proxy` |
| **hosted** | Lưu artifact do mình phát hành | `maven-releases`, `maven-snapshots`, `docker-hosted`, `npm-hosted`, `pypi-hosted` |
| **group** | Gộp nhiều repo sau một URL; client chỉ cần cấu hình một địa chỉ | `maven-public` (releases + snapshots + central), `docker-group`, `npm-group`, `pypi-group` |

Quy ước dùng: **đọc qua group, ghi vào hosted.** Không cấu hình client trỏ thẳng proxy hoặc kho Internet.

### Repository hiện có

| Định dạng | proxy | hosted | group | Tạo bởi |
|---|---|---|---|---|
| Maven | `maven-central` | `maven-releases`, `maven-snapshots` | `maven-public` | Mặc định Nexus |
| NuGet | `nuget.org-proxy` | `nuget-hosted` | `nuget-group` | Mặc định Nexus |
| Docker | `docker-proxy` (Docker Hub, :8002) | `docker-hosted` (:8000) | `docker-group` (:8001) | `bootstrap.sh` |
| npm | `npm-proxy` | `npm-hosted` | `npm-group` | `bootstrap.sh` |
| PyPI | `pypi-proxy` | `pypi-hosted` | `pypi-group` | `bootstrap.sh` |
| Các định dạng khác (apt, yum, raw, conan, Docker proxy cho ghcr/quay/mcr...) | | | | `repos-extra.sh` ([phần 7](07-cau-hinh-theo-cong-nghe.md)) |

## 1.2. Các nhóm cấu hình và ý nghĩa

### Helm values (`helm-install/nexus/nexus-repository-manager/values.yaml`)

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `image.tag` | `3.85.0` | 3.71+ bỏ OrientDB. `/nexus-data` hiện tại tạo bởi 3.85.0: **không quay lại tag cũ hơn** |
| `fullnameOverride` | `nexus` | Tên Deployment/Service `nexus` (manifest Docker chọn pod theo label này) |
| `nexus.env` `INSTALL4J_ADD_VM_PARAMS` | `-Xms2048m -Xmx2048m -XX:MaxDirectMemorySize=1536m ... -Dnexus.scripts.allowCreation=true` | Heap + direct memory phải nhỏ hơn memory limit (4Gi). `scripts.allowCreation` cho phép script API |
| `NEXUS_SECURITY_RANDOMPASSWORD` | `true` | Mật khẩu `admin` ngẫu nhiên, ghi ở `/nexus-data/admin.password` (xoá sau lần đăng nhập đầu) |
| `nexus.properties.override` | `false` | Không mount `nexus.properties` bằng subPath (subPath làm kubelet tạo `/nexus-data/etc` thuộc root, Nexus uid 200 không ghi được) |
| `nexus.resources` | request 1 CPU / 4Gi, limit 2 CPU / 4Gi | |
| `nexus.securityContext` | uid/gid/fsGroup 200 | Chạy non-root |
| `livenessProbe.initialDelaySeconds` | 300 | Lần khởi động đầu (khởi tạo DB) mất vài phút |
| `deployment.initContainers` `fix-permissions` | `chown -R 200:200 /nexus-data` (busybox, chạy root) | Trả quyền thư mục dữ liệu cho uid 200 |
| `deploymentStrategy` | `Recreate` | Volume RWO: pod cũ phải dừng trước khi pod mới gắn volume |
| `persistence` | `gp3`, `20Gi`, RWO | PVC `nexus-data` (độc lập, không dùng `volumeClaimTemplates`): mở rộng bằng sửa `storageSize` + `helm upgrade` |
| `ingress` | ALB group `alb-apps`, HTTP, host `nexus.gitlabonlinecom.click`, health check `/` | Giao diện và mọi định dạng trừ Docker |
| `serviceAccount` | `nexus`, IRSA `eks-nexus-role` | Dành cho blob store S3 (bucket `nexus-data-bucket-s3`, chưa dùng) |
| `nexus.docker.enabled` | `false` | Không dùng cơ chế Docker của chart; cổng Docker mở bằng `manifests/nexus-docker.yaml` |

### Docker connector (`helm-install/nexus/manifests/nexus-docker.yaml`)

Docker registry API nằm ở gốc host (`/v2/`), nên cách đơn giản và ổn định nhất là cho mỗi repo Docker **một cổng riêng** (HTTP connector) và một hostname riêng trên ALB:

| Repo | Cổng (connector) | Hostname | Dùng để |
|---|---|---|---|
| `docker-hosted` | 8000 | `docker-internal.gitlabonlinecom.click` | **push** image nội bộ |
| `docker-group` | 8001 | `docker.gitlabonlinecom.click` | **pull** (hosted + mọi proxy) |
| `docker-proxy` | 8002 | `docker-proxy.gitlabonlinecom.click` | pull riêng Docker Hub |

Service `nexus-docker` mở 3 cổng; 3 Ingress cùng group `alb-apps`, health check `/v2/` chấp nhận `200,401` (registry trả 401 khi chưa đăng nhập). Realm **Docker Bearer Token** được bật trong `bootstrap.sh`; các repo Docker đặt `forceBasicAuth: true` (bắt buộc đăng nhập).

### Blob store

Blob store là nơi lưu file thật (jar, layer image...). Metadata nằm trong DB (H2).

| Blob store | Kiểu | Trạng thái |
|---|---|---|
| `default` | File, trên PVC `/nexus-data/blobs/default` | **Đang dùng cho mọi repo** |
| S3 (`nexus-data-bucket-s3`) | S3 qua IRSA `eks-nexus-role` | Chuẩn bị quyền IAM, chưa tạo bucket và blob store |

Khi có nhiều định dạng, nên tách blob store (ví dụ `docker`, `maven`, `os-packages`) để đặt **quota** riêng và dễ theo dõi dung lượng. Blob store không đổi được sau khi tạo repo (phải tạo repo mới hoặc dùng task *Change repository blob store* ở bản Pro).

### Bảo mật (realm, role, user)

| Thành phần | Cấu hình |
|---|---|
| Realm | Local Authenticating/Authorizing Realm (mặc định), **Docker Bearer Token Realm** (bootstrap thêm) |
| User `admin` | Mật khẩu ngẫu nhiên lúc cài, đổi ở lần đăng nhập đầu |
| User `ci-jenkins` | Role `ci-role`; mật khẩu sinh trong `bootstrap.sh`, chỉ lưu trong Secret `jenkins/nexus-ci` |
| Role `ci-role` | Đọc/browse các group (maven-public, docker-group, npm-group, pypi-group); ghi `maven-releases`, `maven-snapshots`, `docker-hosted`, `npm-hosted`, `pypi-hosted` |
| Role `read-all` | (từ `repos-extra.sh`) đọc/browse mọi repo, cho lập trình viên và máy build |
| Anonymous | Kiểm tra trong Security → Anonymous Access; khuyến nghị tắt hoặc chỉ cho đọc các group cần thiết |

### Write policy của repo hosted

| Policy | Ý nghĩa | Dùng cho |
|---|---|---|
| `allow_once` | Không ghi đè phiên bản đã có (bất biến) | Release: `npm-hosted`, `pypi-hosted`, `maven-releases`, `conan-hosted`, `tools-hosted` |
| `allow` | Cho ghi đè | `maven-snapshots`, `docker-hosted` (tag như `latest`), cache (`vcpkg-cache`) |
| `deny` | Chỉ đọc | Repo đã đóng băng |

## 1.3. Luồng sử dụng trong pipeline

```
Jenkins agent (pod trên node CI)
  mvn ... -s .ci-settings.xml  ──► maven-public  (mirror *)      ──► maven-central ──► Maven Central
  mvn deploy                   ──► maven-snapshots / maven-releases
  docker build (FROM ...)      ──► Docker Hub (trực tiếp, hoặc qua docker.gitlabonlinecom.click nếu Dockerfile dùng)
  docker push                  ──► docker-internal.gitlabonlinecom.click/dev-backend/<app>:<tag> (docker-hosted)
  pip / npm (ci-lib)           ──► pypi-group / npm-group; twine/npm publish ──► *-hosted
```

Mọi credential đến từ `withCredentials` (`nexus-creds`, `docker-user-internal`), file cấu hình (`settings.xml`, `.npmrc`) chỉ chứa tham chiếu biến môi trường.
