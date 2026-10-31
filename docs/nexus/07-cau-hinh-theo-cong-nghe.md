# 7. Cấu hình và sử dụng Nexus theo công nghệ

[← Mục lục Nexus](README.md)

Phần này hướng dẫn tạo repository và cấu hình client cho từng công nghệ: **Docker, Maven/Java/Gradle, Python, Node.js, C/C++, Linux, Windows, AWS, GCP, Azure** và Kubernetes.

## 7.1. Quy ước chung

### Địa chỉ

| Dùng từ | Địa chỉ gốc | Ghi chú |
|---|---|---|
| Ngoài cụm (máy lập trình viên, VM, máy build khác) | `http://nexus.gitlabonlinecom.click/repository/<repo>/` | Qua ALB |
| Pod trong cụm (Jenkins agent, GitLab job) | `http://nexus.nexus.svc.cluster.local:8081/repository/<repo>/` | Không qua ALB, nhanh hơn |
| Docker pull | `docker.gitlabonlinecom.click/<image>` | `docker-group` (:8001) |
| Docker push | `docker-internal.gitlabonlinecom.click/<team>/<image>` | `docker-hosted` (:8000) |

Trong các ví dụ dưới đây, `NEXUS=http://nexus.gitlabonlinecom.click`. Pod trong cụm thay bằng địa chỉ `svc.cluster.local`.

### Tạo repository

```bash
./helm-install/nexus/bootstrap.sh
./helm-install/nexus/repos-extra.sh
```

| Công nghệ | Đọc (group/proxy) | Ghi (hosted) | Script |
|---|---|---|---|
| Docker | `docker-group` ← `docker-proxy` (Hub), `ghcr-proxy`, `quay-proxy`, `k8s-proxy`, `ecr-public-proxy`, `gcr-proxy`, `mcr-proxy` | `docker-hosted` | bootstrap + extra |
| Maven/Java/Gradle | `maven-public` ← `maven-central`, `gradle-plugins-proxy` | `maven-releases`, `maven-snapshots` | mặc định + extra |
| Python | `pypi-group` ← `pypi-proxy` | `pypi-hosted` | bootstrap |
| Node.js | `npm-group` ← `npm-proxy` | `npm-hosted` | bootstrap |
| C/C++ | `conan-proxy` (ConanCenter) | `conan-hosted`, `vcpkg-cache` (raw), `tools-hosted` (raw) | extra |
| Linux | `ubuntu-proxy`, `ubuntu-security-proxy`, `debian-proxy`, `debian-security-proxy` (apt); `rocky-proxy`, `epel-proxy` (yum); `alpine-proxy` (raw) | — | extra |
| Windows | `nuget-group` ← `nuget.org-proxy`; `chocolatey-proxy`, `psgallery-proxy` | `nuget-hosted` | mặc định + extra |
| AWS | `ecr-public-proxy`, `awscli-proxy`; SDK qua các group ngôn ngữ | — | extra |
| GCP | `gcr-proxy`, `google-cloud-apt-proxy`, `google-cloud-yum-proxy` | — | extra |
| Azure | `mcr-proxy`, `azure-cli-apt-proxy`, `azure-cli-yum-proxy` | — | extra |
| HashiCorp (Terraform...) | `hashicorp-apt-proxy`, `hashicorp-yum-proxy`, `hashicorp-releases-proxy` | — | extra |

### Tài khoản

| Đối tượng | User / role |
|---|---|
| Pipeline Jenkins | `ci-jenkins` (`ci-role`), qua credential `nexus-creds` |
| GitLab CI | User máy riêng (ví dụ `ci-gitlab`) role `read-all` + quyền ghi hosted cần thiết; lưu ở biến CI/CD *masked + protected* |
| Lập trình viên, VM | User cá nhân (LDAP khi có) role `read-all`; quyền ghi theo team |

Không ghi mật khẩu vào file trong repo. Dùng biến môi trường, credential helper hoặc file cấu hình trong thư mục home có quyền `600`.

### Lưu ý vì Nexus đang chạy HTTP

| Công cụ | Cần làm |
|---|---|
| Docker | `insecure-registries` trong `daemon.json` (hoặc `--insecure-registry` cho dind) |
| containerd (Kubernetes) | `hosts.toml` với `http://` ([7.12](#712-dùng-nexus-làm-registry-cho-kubernetes)) |
| pip | `trusted-host` |
| Gradle 7+ | `isAllowInsecureProtocol = true` cho từng repo |
| .NET 9+ (NuGet) | `allowInsecureConnections="true"` trong `nuget.config` (không có thì báo lỗi với nguồn HTTP) |
| Maven, npm, Conan, apt, yum, apk, Chocolatey, PowerShell | Chạy được với HTTP (một số cảnh báo) |

Tất cả các mục trên bỏ đi được khi bật HTTPS ([3.3](03-tich-hop-va-bao-mat.md#33-lộ-trình-hardening)).

## 7.2. Docker (proxy, hosted, group)

### Cách hoạt động

- `docker.gitlabonlinecom.click` (`docker-group`) tìm image lần lượt trong `docker-hosted`, `docker-proxy` (Docker Hub), `ghcr-proxy`, `quay-proxy`, `k8s-proxy`, `ecr-public-proxy`, `gcr-proxy`, `mcr-proxy`. Image tìm thấy ở proxy được cache lại.
- Đường dẫn image giữ nguyên phần sau hostname của kho gốc:

| Image gốc | Pull qua Nexus |
|---|---|
| `nginx:1.27` (Docker Hub official) | `docker.gitlabonlinecom.click/library/nginx:1.27` |
| `bitnami/redis:7.4` | `docker.gitlabonlinecom.click/bitnami/redis:7.4` |
| `ghcr.io/actions/actions-runner:latest` | `docker.gitlabonlinecom.click/actions/actions-runner:latest` |
| `quay.io/prometheus/node-exporter:v1.8.2` | `docker.gitlabonlinecom.click/prometheus/node-exporter:v1.8.2` |
| `registry.k8s.io/ingress-nginx/controller:v1.11.3` | `docker.gitlabonlinecom.click/ingress-nginx/controller:v1.11.3` |
| `public.ecr.aws/amazonlinux/amazonlinux:2023` | `docker.gitlabonlinecom.click/amazonlinux/amazonlinux:2023` |
| `gcr.io/distroless/java17-debian12` | `docker.gitlabonlinecom.click/distroless/java17-debian12` |
| `mcr.microsoft.com/dotnet/aspnet:8.0` | `docker.gitlabonlinecom.click/dotnet/aspnet:8.0` |

**Trùng tên:** nếu hai kho có cùng đường dẫn, group trả về bản của member đứng trước. Hiếm gặp vì các kho dùng tên tổ chức khác nhau, nhưng khi cần chắc chắn, pull Docker Hub qua `docker-proxy.gitlabonlinecom.click` (cổng riêng), hoặc tạo cổng/hostname riêng cho kho cần tách (thêm connector, cổng trong Service `nexus-docker` và một Ingress).

### Cấu hình Docker client

`/etc/docker/daemon.json` (Linux) hoặc Docker Desktop → Settings → Docker Engine:

```json
{
  "insecure-registries": [
    "docker.gitlabonlinecom.click",
    "docker-internal.gitlabonlinecom.click",
    "docker-proxy.gitlabonlinecom.click"
  ]
}
```

```bash
sudo systemctl restart docker
docker login docker.gitlabonlinecom.click
docker login docker-internal.gitlabonlinecom.click
docker pull docker.gitlabonlinecom.click/library/eclipse-temurin:17-jre
```

`registry-mirrors` (tự động đưa mọi pull Docker Hub qua Nexus) chỉ hoạt động khi `docker-proxy` cho phép đọc ẩn danh. Khi đã tắt anonymous (khuyến nghị), dùng tiền tố hostname rõ ràng như trên.

### Push image nội bộ

```bash
docker build -t docker-internal.gitlabonlinecom.click/dev-backend/payment-api:1.4.0 .
docker push docker-internal.gitlabonlinecom.click/dev-backend/payment-api:1.4.0
```

Quy ước đường dẫn: `<team>/<app>:<version>` (ví dụ `dev-backend/shopping-cart:0.0.1-SNAPSHOT-a1b2c3d`). Role ghi có thể giới hạn theo đường dẫn bằng content selector (`format == "docker" and path =^ "/v2/dev-backend/"`).

### Dockerfile lấy image nền qua Nexus

```dockerfile
ARG REGISTRY=docker.gitlabonlinecom.click
FROM ${REGISTRY}/library/eclipse-temurin:17-jre
```

Build ngoài công ty có thể đổi `--build-arg REGISTRY=docker.io`.

### Jenkins (docker:dind) và GitLab CI (Kaniko)

Jenkins: container `docker:24-dind` chạy với `--insecure-registry=<hostname>` cho từng hostname cần dùng (`Jenkinsfile` hiện có cho `docker-internal`; thêm `docker.gitlabonlinecom.click` nếu Dockerfile lấy image nền qua Nexus).

GitLab CI với Kaniko (pod không privileged):

```yaml
build-image:
  tags: [eks]
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - AUTH=$(printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASSWORD" | base64 | tr -d '\n')
    - mkdir -p /kaniko/.docker
    - printf '{"auths":{"docker-internal.gitlabonlinecom.click":{"auth":"%s"},"docker.gitlabonlinecom.click":{"auth":"%s"}}}' "$AUTH" "$AUTH" > /kaniko/.docker/config.json
    - /kaniko/executor --context "$CI_PROJECT_DIR" --dockerfile Dockerfile
        --insecure --insecure-pull --skip-tls-verify
        --build-arg REGISTRY=docker.gitlabonlinecom.click
        --destination docker-internal.gitlabonlinecom.click/dev-backend/$CI_PROJECT_NAME:$CI_COMMIT_SHORT_SHA
```

### Cấu hình thêm cho proxy

| Việc | Ở đâu |
|---|---|
| Tài khoản Docker Hub cho `docker-proxy` (tránh rate limit ẩn danh) | Repository → `docker-proxy` → HTTP → Authentication: Username/Password của tài khoản Docker Hub (nên là tài khoản trả phí/tổ chức) |
| Cache metadata tag ngắn hơn (tag `latest` cập nhật nhanh) | Proxy → Maximum metadata age (mặc định 1440 phút) |
| Image Windows (foreign layers) | `mcr-proxy` đã bật *Foreign Layer Caching* |

## 7.3. Maven, Java, Gradle

### Maven: `~/.m2/settings.xml`

```xml
<settings>
  <servers>
    <server><id>nexus</id><username>${env.NEXUS_USER}</username><password>${env.NEXUS_PASSWORD}</password></server>
    <server><id>maven-releases</id><username>${env.NEXUS_USER}</username><password>${env.NEXUS_PASSWORD}</password></server>
    <server><id>maven-snapshots</id><username>${env.NEXUS_USER}</username><password>${env.NEXUS_PASSWORD}</password></server>
  </servers>
  <mirrors>
    <mirror>
      <id>nexus</id>
      <mirrorOf>*</mirrorOf>
      <url>http://nexus.gitlabonlinecom.click/repository/maven-public/</url>
    </mirror>
  </mirrors>
</settings>
```

- `mirrorOf *`: mọi repo (kể cả repo khai báo trong `pom.xml`) đi qua `maven-public`.
- Máy cá nhân có thể lưu mật khẩu mã hoá bằng `mvn --encrypt-master-password` / `mvn --encrypt-password` (file `settings-security.xml`) thay cho biến môi trường.
- Pipeline Jenkins đang dùng đúng mẫu này (file `.ci-settings.xml`, mật khẩu từ `withCredentials`).

### Phát hành artifact: `pom.xml`

```xml
<distributionManagement>
  <repository>
    <id>maven-releases</id>
    <url>http://nexus.gitlabonlinecom.click/repository/maven-releases/</url>
  </repository>
  <snapshotRepository>
    <id>maven-snapshots</id>
    <url>http://nexus.gitlabonlinecom.click/repository/maven-snapshots/</url>
  </snapshotRepository>
</distributionManagement>
```

```bash
mvn -B deploy -DskipTests
```

Phiên bản `-SNAPSHOT` vào `maven-snapshots` (ghi đè được), phiên bản release vào `maven-releases` (`allow_once`: deploy lại cùng version sẽ bị từ chối, đúng ý đồ).

### Gradle: `settings.gradle.kts`

```kotlin
pluginManagement {
    repositories {
        maven {
            url = uri("http://nexus.gitlabonlinecom.click/repository/maven-public/")
            isAllowInsecureProtocol = true
            credentials {
                username = providers.gradleProperty("nexusUser").get()
                password = providers.gradleProperty("nexusPassword").get()
            }
        }
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            url = uri("http://nexus.gitlabonlinecom.click/repository/maven-public/")
            isAllowInsecureProtocol = true
            credentials {
                username = providers.gradleProperty("nexusUser").get()
                password = providers.gradleProperty("nexusPassword").get()
            }
        }
    }
}
```

`maven-public` đã gồm Gradle Plugin Portal (`gradle-plugins-proxy`), nên plugin cũng tải qua Nexus. Mật khẩu đặt trong `~/.gradle/gradle.properties` (`nexusUser=...`, `nexusPassword=...`) hoặc biến môi trường `ORG_GRADLE_PROJECT_nexusUser` / `ORG_GRADLE_PROJECT_nexusPassword` trong CI.

Phát hành (`build.gradle.kts`, plugin `maven-publish`):

```kotlin
publishing {
    publications { create<MavenPublication>("lib") { from(components["java"]) } }
    repositories {
        maven {
            val base = "http://nexus.gitlabonlinecom.click/repository/"
            url = uri(if (version.toString().endsWith("SNAPSHOT")) base + "maven-snapshots/" else base + "maven-releases/")
            isAllowInsecureProtocol = true
            credentials {
                username = providers.gradleProperty("nexusUser").get()
                password = providers.gradleProperty("nexusPassword").get()
            }
        }
    }
}
```

### Maven Wrapper qua Nexus

Bản phân phối Maven cũng nằm trên Maven Central, nên tải được qua `maven-public`. Trong `.mvn/wrapper/maven-wrapper.properties`:

```properties
distributionUrl=http://nexus.gitlabonlinecom.click/repository/maven-public/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip
```

## 7.4. Python

### Cài package: `pip.conf`

Linux/macOS `~/.config/pip/pip.conf` (Windows `%APPDATA%\pip\pip.ini`):

```ini
[global]
index-url = http://nexus.gitlabonlinecom.click/repository/pypi-group/simple
trusted-host = nexus.gitlabonlinecom.click
```

Mật khẩu: dùng `~/.netrc` (quyền `600`), pip tự đọc:

```
machine nexus.gitlabonlinecom.click login <user> password <password>
```

Trong CI dùng biến môi trường thay cho file:

```bash
export PIP_INDEX_URL=http://nexus.nexus.svc.cluster.local:8081/repository/pypi-group/simple
export PIP_TRUSTED_HOST=nexus.nexus.svc.cluster.local
pip install -r requirements.txt
```

(`ci-lib` ghi netrc vào `/tmp` của container build, xem [Jenkins 7.5.3](../jenkins/07-shared-library.md#753-python).)

### Poetry và uv

```bash
poetry source add --priority=primary nexus http://nexus.gitlabonlinecom.click/repository/pypi-group/simple
poetry config http-basic.nexus "$NEXUS_USER" "$NEXUS_PASSWORD"
```

```toml
# pyproject.toml (uv)
[[tool.uv.index]]
name = "nexus"
url = "http://nexus.gitlabonlinecom.click/repository/pypi-group/simple"
default = true
```

uv đọc mật khẩu từ `UV_INDEX_NEXUS_USERNAME` / `UV_INDEX_NEXUS_PASSWORD`; với HTTP thêm `--allow-insecure-host nexus.gitlabonlinecom.click`.

### Phát hành: `~/.pypirc` + twine

```ini
[distutils]
index-servers = nexus

[nexus]
repository = http://nexus.gitlabonlinecom.click/repository/pypi-hosted/
username = <user>
```

```bash
python -m build
TWINE_PASSWORD="$NEXUS_PASSWORD" twine upload -r nexus dist/*
```

Lưu ý URL: cài từ `pypi-group/simple`, upload vào `pypi-hosted/` (không có `simple`).

## 7.5. Node.js (npm, Yarn, pnpm)

### npm: `.npmrc` (thư mục home, quyền `600`)

```ini
registry=http://nexus.gitlabonlinecom.click/repository/npm-group/
//nexus.gitlabonlinecom.click/repository/npm-group/:_auth=${NPM_AUTH}
//nexus.gitlabonlinecom.click/repository/npm-hosted/:_auth=${NPM_AUTH}
```

```bash
export NPM_AUTH=$(printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASSWORD" | base64 | tr -d '\n')
npm ci
```

npm thay `${NPM_AUTH}` bằng biến môi trường, file không chứa mật khẩu. Không commit `.npmrc` có `registry` trỏ ra ngoài vào repo (nó được ưu tiên hơn cấu hình user).

### Phát hành

`package.json`:

```json
{
  "name": "@bank/ui-components",
  "publishConfig": { "registry": "http://nexus.gitlabonlinecom.click/repository/npm-hosted/" }
}
```

```bash
npm publish
```

Package nội bộ nên có **scope** (`@bank/...`). Có thể ép scope chỉ lấy từ hosted để tránh *dependency confusion*:

```ini
@bank:registry=http://nexus.gitlabonlinecom.click/repository/npm-hosted/
```

### Yarn (Berry) và pnpm

`.yarnrc.yml`:

```yaml
npmRegistryServer: "http://nexus.gitlabonlinecom.click/repository/npm-group/"
unsafeHttpWhitelist:
  - nexus.gitlabonlinecom.click
npmAlwaysAuth: true
npmAuthIdent: "${NEXUS_USER}:${NEXUS_PASSWORD}"
```

pnpm đọc `.npmrc` như npm.

## 7.6. C và C++

### Conan 2 (thư viện C/C++)

```bash
conan remote add nexus http://nexus.gitlabonlinecom.click/repository/conan-proxy/
conan remote add nexus-hosted http://nexus.gitlabonlinecom.click/repository/conan-hosted/
conan remote disable conancenter
conan remote login nexus "$NEXUS_USER" -p "$NEXUS_PASSWORD"
conan remote login nexus-hosted "$NEXUS_USER" -p "$NEXUS_PASSWORD"
conan install . --build=missing
```

Phát hành thư viện nội bộ:

```bash
conan create . --version 1.2.0
conan upload "bank-crypto/1.2.0" -r nexus-hosted --confirm
```

- Nexus không có group cho Conan: client tìm theo thứ tự remote (`conan remote list`). Đặt `nexus-hosted` trước nếu tên package nội bộ có thể trùng ConanCenter: `conan remote update nexus-hosted --index 0`.
- Hỗ trợ Conan 2 phụ thuộc phiên bản Nexus. Nếu `repos-extra.sh` báo `FAIL` cho `conan-proxy`, kiểm tra tài liệu Nexus của phiên bản đang chạy (Conan V1/V2).

### vcpkg (binary cache trên raw hosted)

vcpkg lưu bản build sẵn vào `vcpkg-cache`, các máy sau dùng lại, không phải biên dịch lại:

```bash
export NEXUS_BASIC=$(printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASSWORD" | base64 | tr -d '\n')
export VCPKG_BINARY_SOURCES="clear;http,http://nexus.gitlabonlinecom.click/repository/vcpkg-cache/{name}/{version}/{sha}.zip,readwrite,Authorization: Basic ${NEXUS_BASIC}"
vcpkg install
```

Máy chỉ đọc dùng `read` thay cho `readwrite`.

### Công cụ build và SDK

| Thứ cần | Lấy qua Nexus |
|---|---|
| gcc, g++, clang, make, cmake, ninja (Linux) | `apt`/`yum` qua proxy gói Linux ([7.7](#77-linux-apt-yum-apk)) |
| CMake, Ninja bản mới | `pip install cmake ninja` qua `pypi-group` (có bản dựng sẵn cho Linux/Windows/macOS) |
| SDK/toolchain nội bộ, file nhị phân lớn | `tools-hosted` (raw) |

Upload và tải file raw:

```bash
curl -u "$NEXUS_USER:$NEXUS_PASSWORD" --upload-file arm-toolchain-13.2.tar.xz http://nexus.gitlabonlinecom.click/repository/tools-hosted/toolchains/arm-toolchain-13.2.tar.xz
curl -u "$NEXUS_USER:$NEXUS_PASSWORD" -O http://nexus.gitlabonlinecom.click/repository/tools-hosted/toolchains/arm-toolchain-13.2.tar.xz
```

## 7.7. Linux (apt, yum, apk)

Proxy gói Linux chỉ cache gói đã được tải (không mirror toàn bộ kho). Chữ ký GPG của nhà phát hành được giữ nguyên: máy client vẫn kiểm tra chữ ký như bình thường.

### Ubuntu 24.04 (deb822): `/etc/apt/sources.list.d/ubuntu.sources`

```
Types: deb
URIs: http://nexus.gitlabonlinecom.click/repository/ubuntu-proxy/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://nexus.gitlabonlinecom.click/repository/ubuntu-security-proxy/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
```

Mật khẩu trong `/etc/apt/auth.conf.d/nexus.conf` (quyền `600`):

```
machine nexus.gitlabonlinecom.click login <user> password <password>
```

```bash
sudo apt-get update
```

Ubuntu 22.04 (`jammy`) và Debian (`debian-proxy`, `debian-security-proxy`, suite `bookworm`, `bookworm-security`) làm tương tự. Nếu một proxy apt báo lỗi với suite khác `distribution` đã khai báo khi tạo repo, tạo thêm proxy riêng cho suite đó.

### RHEL, Rocky Linux 9: `/etc/yum.repos.d/nexus-rocky.repo`

```ini
[nexus-baseos]
name=Rocky 9 BaseOS (Nexus)
baseurl=http://nexus.gitlabonlinecom.click/repository/rocky-proxy/9/BaseOS/$basearch/os/
username=<user>
password=<password>
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1

[nexus-appstream]
name=Rocky 9 AppStream (Nexus)
baseurl=http://nexus.gitlabonlinecom.click/repository/rocky-proxy/9/AppStream/$basearch/os/
username=<user>
password=<password>
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1

[nexus-epel]
name=EPEL 9 (Nexus)
baseurl=http://nexus.gitlabonlinecom.click/repository/epel-proxy/9/Everything/$basearch/
username=<user>
password=<password>
gpgcheck=1
gpgkey=https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9
enabled=1
```

Tắt các repo gốc (`dnf config-manager --set-disabled baseos appstream extras`), rồi `sudo dnf makecache`. File `.repo` chứa mật khẩu: đặt quyền `600` và quản lý bằng công cụ cấu hình (Ansible Vault...).

### Alpine: `/etc/apk/repositories`

```
http://<user>:<password>@nexus.gitlabonlinecom.click/repository/alpine-proxy/v3.20/main
http://<user>:<password>@nexus.gitlabonlinecom.click/repository/alpine-proxy/v3.20/community
```

Trong Dockerfile, không ghi mật khẩu vào layer: dùng BuildKit secret.

```dockerfile
# syntax=docker/dockerfile:1
FROM docker.gitlabonlinecom.click/library/alpine:3.20
RUN --mount=type=secret,id=nexus_auth \
    AUTH=$(cat /run/secrets/nexus_auth) && \
    printf 'http://%s@nexus.gitlabonlinecom.click/repository/alpine-proxy/v3.20/main\n' "$AUTH" > /etc/apk/repositories && \
    apk add --no-cache curl && \
    printf 'https://dl-cdn.alpinelinux.org/alpine/v3.20/main\n' > /etc/apk/repositories
```

```bash
printf '%s:%s' "$NEXUS_USER" "$NEXUS_PASSWORD" > /tmp/nexus_auth
docker build --secret id=nexus_auth,src=/tmp/nexus_auth -t myimage .
rm -f /tmp/nexus_auth
```

Cách tương tự cho `apt` trong Dockerfile Debian/Ubuntu (mount secret thành `/etc/apt/auth.conf.d/nexus.conf`).

## 7.8. Windows (NuGet, Chocolatey, PowerShell, container)

### NuGet / .NET: `nuget.config`

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nexus" value="http://nexus.gitlabonlinecom.click/repository/nuget-group/index.json" allowInsecureConnections="true" />
  </packageSources>
  <packageSourceCredentials>
    <nexus>
      <add key="Username" value="%NEXUS_USER%" />
      <add key="ClearTextPassword" value="%NEXUS_PASSWORD%" />
    </nexus>
  </packageSourceCredentials>
</configuration>
```

`<clear />` bỏ nuget.org mặc định, mọi package đi qua Nexus. Giá trị `%VAR%` lấy từ biến môi trường, file không chứa mật khẩu.

Phát hành vào `nuget-hosted` cần **NuGet API Key**: bật realm *NuGet API-Key Realm* (Security → Realms), user lấy key tại avatar → *NuGet API Key*.

```bash
dotnet pack -c Release
dotnet nuget push bin/Release/Bank.Common.1.0.0.nupkg -s http://nexus.gitlabonlinecom.click/repository/nuget-hosted/ -k "$NUGET_API_KEY"
```

### Chocolatey (cài phần mềm trên Windows)

```powershell
choco source disable -n=chocolatey
choco source add -n=nexus -s="http://nexus.gitlabonlinecom.click/repository/chocolatey-proxy/" -u="$env:NEXUS_USER" -p="$env:NEXUS_PASSWORD" --priority=1
choco install git 7zip -y
```

Gói Chocolatey cộng đồng thường tải file cài đặt từ trang của nhà phát hành (không nằm trong `.nupkg`). Môi trường không có Internet cần *internalize* gói (đóng gói kèm file cài đặt) và đẩy vào một NuGet hosted riêng (ví dụ `chocolatey-hosted`).

### PowerShell Gallery

PowerShellGet 2.x:

```powershell
$cred = Get-Credential
Register-PSRepository -Name Nexus -SourceLocation "http://nexus.gitlabonlinecom.click/repository/psgallery-proxy/" -InstallationPolicy Trusted -Credential $cred
Install-Module -Name Az.Accounts -Repository Nexus -Credential $cred
```

PSResourceGet (PowerShell 7.4+):

```powershell
Register-PSResourceRepository -Name Nexus -Uri "http://nexus.gitlabonlinecom.click/repository/psgallery-proxy/" -Trusted
Install-PSResource -Name Az.Accounts -Repository Nexus -Credential (Get-Credential)
```

### Docker trên Windows

`C:\ProgramData\docker\config\daemon.json`:

```json
{ "insecure-registries": ["docker.gitlabonlinecom.click", "docker-internal.gitlabonlinecom.click"] }
```

```powershell
Restart-Service docker
docker pull docker.gitlabonlinecom.click/windows/servercore:ltsc2022
```

Image Windows (`mcr.microsoft.com/windows/...`) có *foreign layers* trỏ về máy chủ Microsoft; `mcr-proxy` bật *Foreign Layer Caching* để các layer này cũng được cache trong Nexus.

## 7.9. AWS

| Nhu cầu | Cách làm với Nexus |
|---|---|
| Image công khai của AWS (Amazon Linux, Lambda base, EKS add-on) | `ecr-public-proxy` qua `docker-group`: `public.ecr.aws/lambda/python:3.12` → `docker.gitlabonlinecom.click/lambda/python:3.12` |
| Image trong **ECR private** | Docker proxy trỏ tới ECR, mật khẩu là token ECR được làm mới định kỳ (dưới đây) |
| AWS CLI v2 | `awscli-proxy` (raw): `curl -u "$NEXUS_USER:$NEXUS_PASSWORD" -o awscliv2.zip http://nexus.gitlabonlinecom.click/repository/awscli-proxy/awscli-exe-linux-x86_64.zip` |
| SDK | `boto3` qua `pypi-group`, `software.amazon.awssdk` qua `maven-public`, `@aws-sdk/*` qua `npm-group`, `AWSSDK.*` qua `nuget-group` |
| Terraform, Packer | `hashicorp-releases-proxy`: `http://nexus.gitlabonlinecom.click/repository/hashicorp-releases-proxy/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip`; hoặc `hashicorp-apt-proxy`/`hashicorp-yum-proxy` |
| Lưu blob của Nexus trên S3 | Blob store S3 với IRSA `eks-nexus-role` ([2.3](02-sizing.md#23-ví-dụ-values-cho-mức-tải-vừa)) |
| CodeArtifact làm nguồn | Proxy Maven/npm/PyPI trỏ tới endpoint CodeArtifact, mật khẩu là token CodeArtifact (hết hạn tối đa 12 giờ, làm mới như ECR) |

### Proxy ECR private (token tự làm mới)

1. Tạo docker proxy `ecr-private-proxy` trỏ tới `https://609320954321.dkr.ecr.ap-southeast-1.amazonaws.com`, *Docker index*: `Use proxy registry`, HTTP Authentication: username `AWS`, password tạm thời bất kỳ. Thêm vào `docker-group` (sửa danh sách member trong `repos-extra.sh`).
2. Token ECR hết hạn sau 12 giờ, nên chạy một CronJob 6 giờ/lần dùng IRSA `eks-nexus-role` (đã có `ecr:GetAuthorizationToken`) để lấy token mới và cập nhật proxy qua REST API. Ví dụ (chưa triển khai):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ecr-token-refresh
  namespace: nexus
spec:
  schedule: "0 */6 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: nexus
          restartPolicy: OnFailure
          containers:
            - name: refresh
              image: amazon/aws-cli:2.38.1
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  TOKEN=$(aws ecr get-login-password --region ap-southeast-1)
                  BODY=$(curl -sf -u "$NX_ADMIN" http://nexus:8081/service/rest/v1/repositories/docker/proxy/ecr-private-proxy)
                  BODY=$(printf '%s' "$BODY" | jq --arg t "$TOKEN" '.httpClient.authentication = {type: "username", username: "AWS", password: $t}')
                  curl -sf -u "$NX_ADMIN" -X PUT -H 'Content-Type: application/json' -d "$BODY" http://nexus:8081/service/rest/v1/repositories/docker/proxy/ecr-private-proxy
              env:
                - name: NX_ADMIN
                  valueFrom:
                    secretKeyRef: { name: nexus-admin-api, key: userpass }
```

Secret `nexus-admin-api` chứa `user:password` của một user Nexus chỉ có quyền sửa repo (`nx-repository-admin-docker-ecr-private-proxy-*`), không dùng `admin`.

## 7.10. GCP

| Nhu cầu | Cách làm với Nexus |
|---|---|
| Image công khai trên `gcr.io` (distroless, kaniko...) | `gcr-proxy` qua `docker-group`: `gcr.io/distroless/static-debian12` → `docker.gitlabonlinecom.click/distroless/static-debian12` |
| Image trong **Artifact Registry** private | Docker proxy trỏ `https://asia-southeast1-docker.pkg.dev`; Authentication: username `_json_key`, password là nội dung JSON key của service account chỉ có `roles/artifactregistry.reader`. Image: `asia-southeast1-docker.pkg.dev/<project>/<repo>/<image>` → `docker.gitlabonlinecom.click/<project>/<repo>/<image>` |
| Maven/Python/npm trên Artifact Registry | Proxy tương ứng trỏ tới endpoint Artifact Registry (`https://asia-southeast1-maven.pkg.dev/<project>/<repo>`, `https://asia-southeast1-python.pkg.dev/<project>/<repo>/simple`), username `_json_key_base64`, password là JSON key mã hoá base64 |
| Google Cloud CLI (`gcloud`) | apt: `deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://nexus.gitlabonlinecom.click/repository/google-cloud-apt-proxy/ cloud-sdk main`; yum: `baseurl=http://nexus.gitlabonlinecom.click/repository/google-cloud-yum-proxy/repos/cloud-sdk-el9-x86_64` |
| SDK | `google-cloud-*` qua `pypi-group`, `com.google.cloud` qua `maven-public`, `@google-cloud/*` qua `npm-group`, `Google.Cloud.*` qua `nuget-group` |

Khoá GPG của Google (`cloud.google.gpg`) tải một lần từ `https://packages.cloud.google.com/apt/doc/apt-key.gpg` và phân phối bằng công cụ cấu hình. JSON key của service account là thông tin nhạy cảm: chỉ cấp quyền đọc, xoay vòng định kỳ, chỉ nhập trên giao diện Nexus (không lưu trong Git).

## 7.11. Azure

| Nhu cầu | Cách làm với Nexus |
|---|---|
| Image của Microsoft (.NET, SQL Server, Windows, Azure CLI) | `mcr-proxy` qua `docker-group`: `mcr.microsoft.com/dotnet/sdk:8.0` → `docker.gitlabonlinecom.click/dotnet/sdk:8.0` |
| Image trong **ACR** private | Docker proxy trỏ `https://<registry>.azurecr.io`; Authentication: **repository-scoped token** của ACR (username = tên token, password = mật khẩu token) chỉ có quyền `content/read`, hoặc service principal `AcrPull` |
| Azure CLI | apt: `deb [signed-by=/etc/apt/keyrings/microsoft.gpg] http://nexus.gitlabonlinecom.click/repository/azure-cli-apt-proxy/ noble main`; yum: `baseurl=http://nexus.gitlabonlinecom.click/repository/azure-cli-yum-proxy/` |
| Azure Artifacts làm nguồn | Proxy NuGet/npm/Maven/PyPI trỏ tới feed Azure Artifacts, Authentication bằng PAT (scope *Packaging: Read*) |
| Module PowerShell `Az` | `psgallery-proxy` ([7.8](#78-windows-nuget-chocolatey-powershell-container)) |
| SDK | `Azure.*` qua `nuget-group`, `azure-*` qua `pypi-group`, `com.azure` qua `maven-public`, `@azure/*` qua `npm-group` |

## 7.12. Dùng Nexus làm registry cho Kubernetes

Áp dụng cho EKS (hiện tại), và tương tự cho GKE/AKS: node cần (1) cho containerd pull từ registry HTTP, (2) credential pull.

### 1. containerd trên node (registry HTTP)

Tạo `/etc/containerd/certs.d/docker.gitlabonlinecom.click/hosts.toml`:

```toml
server = "http://docker.gitlabonlinecom.click"

[host."http://docker.gitlabonlinecom.click"]
  capabilities = ["pull", "resolve"]
```

Tuỳ chọn, đưa mọi pull Docker Hub qua Nexus, `/etc/containerd/certs.d/docker.io/hosts.toml`:

```toml
server = "https://registry-1.docker.io"

[host."http://docker-proxy.gitlabonlinecom.click"]
  capabilities = ["pull", "resolve"]
```

(Mirror cho `docker.io` chỉ dùng được khi `docker-proxy` cho phép đọc ẩn danh, vì kubelet không gửi `imagePullSecrets` tới mirror theo cách này.)

| Nền tảng | Cách đưa file lên node |
|---|---|
| EKS (managed node group, AL2023) | Thêm script vào `cloudinit_pre_nodeadm` của node group trong `eks.tf` (đang dùng cơ chế này cho `kubelet.shutdownGracePeriod`) để ghi file trước khi containerd khởi động; node mới mới nhận cấu hình |
| GKE | DaemonSet đặc quyền ghi file vào `/etc/containerd/certs.d` của node rồi khởi động lại containerd (GKE không cho sửa trực tiếp image node) |
| AKS | DaemonSet tương tự, hoặc custom node configuration |

Cách lâu dài, không cần sửa node: **bật HTTPS cho registry** (ACM trên ALB), khi đó node pull như registry thông thường.

### 2. Credential pull

```bash
read -r -s -p "Nexus pull password: " NX_PASS; echo
kubectl -n <app-namespace> create secret docker-registry nexus-pull --docker-server=docker.gitlabonlinecom.click --docker-username=k8s-pull --docker-password="$NX_PASS"
unset NX_PASS
kubectl -n <app-namespace> patch serviceaccount default -p '{"imagePullSecrets":[{"name":"nexus-pull"}]}'
```

User `k8s-pull` chỉ có role đọc `docker-group`. Với GitOps, quản lý secret này bằng External Secrets (đã có `aws-external-secret-k8s.tf`) thay vì tạo tay.

## 7.13. Sự cố thường gặp theo công nghệ

| Công cụ | Triệu chứng | Cách xử lý |
|---|---|---|
| Docker | `http: server gave HTTP response to HTTPS client` | Thêm hostname vào `insecure-registries` |
| Docker | `unauthorized: access to the requested resource is not authorized` | `docker login <hostname>`; user có quyền đọc repo |
| Docker | `toomanyrequests` | Tài khoản Docker Hub cho `docker-proxy` |
| Docker | `manifest unknown` qua group | Đường dẫn sai (thiếu `library/` cho image official), hoặc proxy kho đó chưa có trong `docker-group` |
| Maven | `Blocked mirror for repositories` | Bản Maven chặn repo HTTP khai báo trong POM: giữ mirror `*` trong `settings.xml` (mirror của user được ưu tiên) |
| Maven | `401` khi deploy | `<server><id>` phải trùng `id` trong `distributionManagement` |
| Maven | `400 Repository does not allow updating assets` | Deploy lại release đã có (`allow_once`): tăng version |
| Gradle | `Using insecure protocols with repositories ... is not allowed` | `isAllowInsecureProtocol = true` |
| pip | `is not a trusted or secure host` | `trusted-host` / `PIP_TRUSTED_HOST` |
| pip/twine | `405 Method Not Allowed` khi upload | Upload vào `pypi-hosted/`, không phải `pypi-group/simple` |
| npm | `E401` | `_auth` đúng đường dẫn registry (có dấu `/` cuối); biến `NPM_AUTH` đã export |
| npm | Vẫn tải từ registry.npmjs.org | `.npmrc` của project ghi đè `registry` |
| .NET | `NU1302` nguồn HTTP | `allowInsecureConnections="true"` |
| NuGet push | `403` | Bật NuGet API-Key Realm, dùng API key của user có quyền ghi `nuget-hosted` |
| Conan | `ERROR: ... 401` | `conan remote login`; user có quyền repo conan |
| apt | `401 Unauthorized` | `/etc/apt/auth.conf.d/nexus.conf` đúng host, quyền `600` |
| apt | `NO_PUBKEY` | Khoá GPG của nhà phát hành chưa cài (proxy không thay khoá) |
| yum/dnf | `Status code: 404` cho repomd.xml | Sai đường dẫn phiên bản/kiến trúc trong `baseurl` |
| Mọi loại | Proxy trả 502/404 dù kho gốc có | Proxy bị *auto-blocked* (Repository → proxy → Unblock); pod Nexus không ra được Internet |
