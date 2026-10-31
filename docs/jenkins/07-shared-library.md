# 7. Shared Library dùng chung cho CI/CD (Java, Spring Boot, Maven, Python, Node.js)

[← Mục lục Jenkins](README.md)

Tài liệu này mô tả thư viện pipeline dùng chung **`ci-lib`**: mỗi ứng dụng chỉ cần một `Jenkinsfile` vài dòng, còn các bước build, test, quét chất lượng, quét bảo mật và đẩy artifact do nhóm platform viết và quản lý tập trung.

Mã nguồn tham chiếu: [`helm-install/jenkins/shared-library/`](../../helm-install/jenkins/shared-library/). Khi triển khai, thư mục này được đưa sang repo GitLab riêng `devops/ci-cd/jenkins-shared-library`.

## 7.1. Vì sao cần Shared Library

| Không có thư viện chung (hiện tại) | Có `ci-lib` |
|---|---|
| Mỗi repo một `Jenkinsfile` khoảng 300 dòng, copy từ repo khác rồi sửa | `Jenkinsfile` khoảng 5 dòng, chỉ khai báo loại ứng dụng và vài tham số |
| Sửa một lỗi (ví dụ đổi image `jnlp`, thêm `safe.directory`) phải sửa từng repo | Sửa một chỗ, phát hành phiên bản mới, các repo nâng phiên bản |
| Team có thể tắt Trivy, bỏ Quality Gate, đổi `exit-code` thành `0` | Cổng bảo mật nằm trong thư viện, app không tắt được; ngoại lệ phải có hạn và được Security duyệt |
| Endpoint, credential ID, image rải rác trong từng repo | Khai báo một lần trong `ciConfig` |
| Kiểm toán (PCI DSS 6.2, 6.3) phải xem từng pipeline | Kiểm toán một thư viện, mọi app dùng cùng quy trình |

## 7.2. Kiến trúc

```
Repo ứng dụng (GitLab)                     Repo devops/ci-cd/jenkins-shared-library (GitLab)
┌──────────────────────────────┐           ┌──────────────────────────────────────────────┐
│ Jenkinsfile                  │  @Library │ vars/ciPipeline.groovy   luồng chuẩn         │
│   @Library('ci-lib@v1.0.0') _│ ────────► │ vars/ciConfig.groovy     cấu hình nền tảng   │
│   ciPipeline(type: 'maven',  │           │ vars/ciPod.groovy        pod agent           │
│              name: 'x')      │           │ vars/ciMaven|ciPython|ciNode.groovy          │
│ pom.xml / pyproject.toml /   │           │ vars/ciImage.groovy      docker, Trivy, push │
│ package.json, Dockerfile     │           │ resources/ci/maven-settings.xml              │
└──────────────────────────────┘           └──────────────────────────────────────────────┘
                │                                              │ JCasC globalLibraries (trusted)
                ▼                                              ▼
        Jenkins controller ──► Pod agent trên node group ci-agents:
                               jnlp │ build (maven/python/node) │ sonar │ docker (dind) │ trivy
                                      │                ▼                 ▼            ▼
                                      ▼            SonarQube        Nexus docker   Trivy server
                                  Nexus (maven-public, pypi-group, npm-group; *-hosted khi publish)
```

| File | Vai trò |
|---|---|
| `vars/ciPipeline.groovy` | Điểm vào duy nhất. Kiểm tra tham số, dựng pod, chạy các stage theo thứ tự cố định |
| `vars/ciConfig.groovy` | `ciConfig()`: endpoint Nexus/Trivy/SonarQube, credential ID, image được phép dùng. `ciConfig.app(args)`: kiểm tra và điền mặc định cho tham số của app |
| `vars/ciPod.groovy` | Tạo pod agent: `jnlp`, `build` theo ngôn ngữ và phiên bản, `sonar`, cộng thêm `docker` + `trivy` nếu build image. Pod chạy trên node group `ci-agents` (nodeSelector + toleration) |
| `vars/ciMaven.groovy` | Java/Spring Boot: `mvn verify` (test + JaCoCo), Sonar qua `sonar-maven-plugin`, `mvn deploy` |
| `vars/ciPython.groovy` | Python: venv, `pytest` + `pytest-cov`, `sonar-scanner`, `twine upload` |
| `vars/ciNode.groovy` | Node.js: `npm ci`, `lint`, `test:ci`, `build`, `sonar-scanner`, `npm publish` |
| `vars/ciImage.groovy` | `docker build` (gắn label OCI: commit, version), Trivy (báo cáo JSON/bảng + cổng HIGH/CRITICAL), `docker push` |
| `resources/ci/maven-settings.xml` | Maven mirror về Nexus, credential đọc từ biến môi trường (không chứa secret) |

## 7.3. Luồng pipeline chuẩn

```
Checkout → Build & Test → SonarQube Analysis → Quality Gate → Publish Package → Docker Build → Trivy Scan Image → Push Image
```

| Stage | Nhánh tính năng / MR | `develop`, `release/*`, `main` |
|---|---|---|
| Checkout, Build & Test, SonarQube, Quality Gate | Chạy | Chạy |
| Publish Package (jar, wheel, npm) | Bỏ qua | Chạy nếu `publish: true` |
| Docker Build, Trivy | Chạy (phát hiện lỗ hổng sớm) | Chạy |
| Push Image | Bỏ qua | Chạy |

Quy ước chung:

- **Tag image:** `<version>-<commit ngắn>`, ví dụ `1.0.0-a1b2c3d`. Version lấy từ `pom.xml`, `pyproject.toml`/`VERSION` hoặc `package.json`, nên từ tag image biết ngay phiên bản và commit.
- **SonarQube `projectVersion`** = version của app (không phải commit), để "New Code" là phần thay đổi kể từ lần đổi version.
- **Mỗi nhánh chỉ một build cùng lúc** (`disableConcurrentBuilds`), giữ 20 build và artifact của 10 build gần nhất; cả pipeline có timeout 60 phút.
- **Trivy:** lỗ hổng HIGH/CRITICAL làm build **FAILED**. Ngoại lệ xem [7.8](#78-bảo-mật-và-quản-trị-môi-trường-ngân-hàng).

## 7.4. Tham số của `ciPipeline`

| Tham số | Bắt buộc | Mặc định | Ý nghĩa |
|---|---|---|---|
| `type` | Có | — | `maven` (Java, Spring Boot), `python`, `node` |
| `name` | Có | — | Tên app, dùng cho tên image |
| `sonarProjectKey` | | `name` | Project key trên SonarQube |
| `javaVersion` | | `17` | `8`, `11`, `17`, `21` (chỉ cho `maven`) |
| `pythonVersion` | | `3.12` | `3.12`, `3.13` |
| `nodeVersion` | | `22` | `22`, `24` |
| `imageGroup` | | `dev-backend` | Thư mục image trên Nexus: `<registry>/<imageGroup>/<name>` |
| `dockerfile` | | `Dockerfile` | Đường dẫn Dockerfile |
| `buildImage` | | `true` | `false` cho thư viện (không có image) |
| `publish` | | `true` với `maven`, `false` với loại khác | Đẩy package lên Nexus (jar, wheel, npm) |
| `trivyWaiverUntil` | | — | `YYYY-MM-DD`: đến hết ngày này, lỗ hổng HIGH/CRITICAL chỉ làm build **UNSTABLE** |
| `pomFile` | | `pom.xml` | (Maven) đường dẫn POM, ví dụ `services/api/pom.xml`; không chứa `..` |
| `mavenGoals` | | `clean verify` | (Maven) goal của bước Build & Test; phải gồm test + JaCoCo |
| `mavenArgs` | | (trống) | (Maven) tuỳ chọn thêm cho mọi lệnh `mvn` (build, Sonar, deploy), ví dụ `-Pci -pl api -am`. Chỉ cho phép chữ, số, khoảng trắng và `. _ : = , / @ + -` (chặn `;`, `$`, `\|`, `&`, nháy) |

Với app Maven, dùng **`mavenPipeline(...)`**: giống `ciPipeline(type: 'maven', ...)` nhưng không cần ghi `type`.

Tham số sai tên, sai loại hoặc phiên bản không có trong danh sách sẽ làm build dừng ngay với thông báo rõ ràng. Ví dụ `javaVersion: '11'` báo `maven version 11 not supported, use one of [8, 17, 21]`. Danh sách phiên bản và image do nhóm platform quản lý trong `ciConfig`, nên không ai dùng được image tuỳ ý.

Các giá trị `name`, `sonarProjectKey`, `imageGroup`, `dockerfile` được kiểm tra bằng biểu thức chính quy (chỉ chữ, số, `.`, `_`, `-`, `/`) trước khi đưa vào lệnh shell, để chặn chèn lệnh qua `Jenkinsfile`.

## 7.5. Hướng dẫn theo từng loại ứng dụng

### 7.5.1. Spring Boot (Maven)

```groovy
@Library('ci-lib@v1.0.0') _

mavenPipeline(
  name: 'shopping-cart',
  javaVersion: '8',
  trivyWaiverUntil: '2026-12-31'
)
```

Dự án nhiều module (`helm-install/jenkins/shared-library/examples/Jenkinsfile.maven-multimodule`):

```groovy
mavenPipeline(name: 'payment-api', javaVersion: '17', mavenArgs: '-Pci -pl payment-api -am', dockerfile: 'payment-api/Dockerfile')
```

**Thư viện chạy:**

| Bước | Lệnh / container |
|---|---|
| Build & Test | `mvn -B -s .ci-settings.xml clean verify` trong `build` (Maven + JDK theo `javaVersion`); kết quả JUnit `**/target/surefire-reports/*.xml` |
| SonarQube | `sonar-maven-plugin` trên JDK 17+. Với `javaVersion: '8'`, thư viện thêm container `sonar` (Maven JDK 17) chỉ để phân tích, còn build vẫn ở JDK 8 |
| Publish | `mvn deploy -DskipTests` lên `maven-releases` / `maven-snapshots` |
| Image | `docker build` từ `Dockerfile` của repo |

**Yêu cầu với repo (contract):**

- Plugin JaCoCo với goal `report` gắn vào phase `verify`, ra `target/site/jacoco/jacoco.xml` (Quality Gate cần coverage).
- `distributionManagement` với id `maven-releases` / `maven-snapshots` khi `publish: true`:
  ```xml
  <distributionManagement>
    <repository><id>maven-releases</id><url>http://nexus.nexus.svc.cluster.local:8081/repository/maven-releases/</url></repository>
    <snapshotRepository><id>maven-snapshots</id><url>http://nexus.nexus.svc.cluster.local:8081/repository/maven-snapshots/</url></snapshotRepository>
  </distributionManagement>
  ```
- Không cần `settings.xml` riêng: thư viện tạo `.ci-settings.xml` trỏ mirror về `maven-public`.

**Chọn JDK:**

| Ứng dụng | `javaVersion` |
|---|---|
| Spring Boot 1.5 / 2.x cũ (cần `javax.xml.bind`) | `8` |
| Spring Boot 2.7, 3.x | `17` |
| Spring Boot 3.2+ muốn dùng virtual threads | `21` |

**Dockerfile gợi ý cho Spring Boot 2.3+** (layered jar: lớp dependency ít đổi được cache, image nhỏ, chạy non-root):

```dockerfile
FROM eclipse-temurin:17-jre-alpine AS extract
WORKDIR /app
COPY target/*.jar app.jar
RUN java -Djarmode=layertools -jar app.jar extract

FROM eclipse-temurin:17-jre-alpine
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=extract /app/dependencies/ ./
COPY --from=extract /app/spring-boot-loader/ ./
COPY --from=extract /app/snapshot-dependencies/ ./
COPY --from=extract /app/application/ ./
USER app
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "org.springframework.boot.loader.launch.JarLauncher"]
```

Với Spring Boot 3.2 trở xuống, launcher là `org.springframework.boot.loader.JarLauncher`.

### 7.5.2. Thư viện Java (Maven, không có image)

```groovy
@Library('ci-lib@v1.0.0') _

mavenPipeline(name: 'common-utils', javaVersion: '21', buildImage: false)
```

Pod không có container `docker` và `trivy`, nên nhẹ hơn. Jar được `mvn deploy` lên Nexus (từ `develop`, `release/*`, `main`); các app khác dùng qua `maven-public`.

### 7.5.3. Python

```groovy
@Library('ci-lib@v1.0.0') _

ciPipeline(type: 'python', name: 'payment-api', pythonVersion: '3.12')
```

**Thư viện chạy** (container `build` = `python:<version>-slim`):

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt            # nếu có
pip install -r requirements-dev.txt        # nếu có
pip install -e '.[test]'                   # nếu chỉ có pyproject.toml
pip install pytest pytest-cov
pytest --junitxml=reports/junit.xml --cov=. --cov-report=xml:coverage.xml
```

Sau đó `sonar-scanner` (container `sonar`) đọc `coverage.xml` và `reports/junit.xml`. Khi `publish: true`: `python -m build` rồi `twine upload` lên `pypi-hosted`.

**Contract:**

- `requirements.txt` (+ `requirements-dev.txt` cho pytest và các công cụ test) **hoặc** `pyproject.toml` cài được bằng pip.
- Test chạy được bằng `pytest` từ thư mục gốc repo.
- Version trong `pyproject.toml` (`[project]` hoặc `[tool.poetry]`) hoặc file `VERSION`; không có thì dùng `0.0.0`.
- Cấu hình phạm vi coverage trong `pyproject.toml` để không tính file test:
  ```toml
  [tool.coverage.run]
  source = ["app"]
  omit = ["tests/*"]
  ```

**Cách lấy package:** pip lấy từ `pypi-group` trên Nexus (biến `PIP_INDEX_URL`). Mật khẩu nằm trong file netrc ở `/tmp` của container build (`NETRC`), không nằm trong workspace và không hiện trong log.

**Dockerfile gợi ý:**

```dockerfile
FROM python:3.12.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 10001 app
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/
USER app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Nếu `docker build` cũng cần tải package qua Nexus (mạng chặn pypi.org), truyền `--build-arg PIP_INDEX_URL=...`. Đây là phần mở rộng cho v1.1 (xem [7.10](#710-mở-rộng-thư-viện)).

### 7.5.4. Node.js

```groovy
@Library('ci-lib@v1.0.0') _

ciPipeline(type: 'node', name: 'customer-portal', nodeVersion: '22', imageGroup: 'dev-frontend')
```

**Thư viện chạy** (container `build` = `node:<version>-alpine`):

```bash
npm ci
npm run lint --if-present
JEST_JUNIT_OUTPUT_DIR=reports npm run test:ci
npm run build --if-present
```

Sau đó `sonar-scanner` đọc `coverage/lcov.info`. Khi `publish: true` (thư viện npm): `npm publish` lên `npm-hosted`.

**Contract:**

- `package.json` + `package-lock.json` (bắt buộc cho `npm ci`, đảm bảo build lặp lại được).
- Script `test:ci` ghi JUnit ra `reports/junit.xml` và LCOV ra `coverage/lcov.info`. Ví dụ với Jest:
  ```json
  {
    "scripts": {
      "lint": "eslint .",
      "test:ci": "jest --ci --coverage --reporters=default --reporters=jest-junit",
      "build": "tsc -p tsconfig.build.json"
    },
    "devDependencies": { "jest": "^29.7.0", "jest-junit": "^16.0.0" }
  }
  ```
  Với Vitest: `"test:ci": "vitest run --coverage --reporter=default --reporter=junit --outputFile.junit=reports/junit.xml"` (coverage provider `lcov`).
- Không đặt `registry=` trỏ ra ngoài trong `.npmrc` của repo. File `.npmrc` của project được ưu tiên hơn cấu hình của thư viện và sẽ bỏ qua Nexus.

**Cách lấy package:** npm dùng `.ci-npmrc` do thư viện tạo (`registry` = `npm-group`). File chỉ chứa `${NPM_AUTH}`; giá trị được tính ngay trong từng lệnh `sh` từ credential Nexus, nên không ghi ra đĩa và không hiện trong log.

**Dockerfile gợi ý (service Node.js):**

```dockerfile
FROM node:22.21.1-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

FROM node:22.21.1-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
USER node
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

Với frontend (React/Vue/Angular): stage cuối dùng `nginxinc/nginx-unprivileged` và copy thư mục build vào `/usr/share/nginx/html`.

## 7.6. Chuẩn bị nền tảng (làm một lần)

### Bước 1. Tạo repo thư viện trên GitLab

Tạo project `devops/ci-cd/jenkins-shared-library` trên GitLab (giao diện, **không** tạo README), rồi từ thư mục repo `terraform-eks-devops-tools`:

```bash
rm -rf /tmp/ci-lib
cp -R helm-install/jenkins/shared-library /tmp/ci-lib
cd /tmp/ci-lib
rm -rf build .gradle
gradle test
git init -b main
git add .
git commit -m "ci-lib v1.0.0: Maven, Python, Node.js pipelines"
git remote add origin http://gitlab.gitlabonlinecom.click/devops/ci-cd/jenkins-shared-library.git
git push -u origin main
git tag v1.0.0
git push origin v1.0.0
```

`gradle test` là tuỳ chọn trên máy có Gradle (chạy 26 unit test, [7.12](#712-kiểm-thử-thư-viện)).

Trên GitLab: **Settings → Repository → Protected branches**: `main` chỉ Maintainer được merge, không ai push trực tiếp. **Protected tags**: `v*` chỉ Maintainer tạo. Bật **Merge request approvals** (ít nhất 1–2 người nhóm platform) và thêm `CODEOWNERS`.

### Bước 2. Khai báo thư viện trong Jenkins (JCasC)

Đã có trong `controller.JCasC.configScripts.shared-library` của `helm-install/jenkins/jenkins/values.yaml`:

```yaml
      shared-library: |
        unclassified:
          globalLibraries:
            libraries:
              - name: "ci-lib"
                defaultVersion: "v1.0.0"
                implicit: false
                allowVersionOverride: true
                includeInChangesets: false
                retriever:
                  modernSCM:
                    scm:
                      git:
                        remote: "http://gitlab.gitlabonlinecom.click/devops/ci-cd/jenkins-shared-library.git"
                        credentialsId: "gitlab-token-dev-group"
```

| Khoá | Lý do |
|---|---|
| `implicit: false` | App phải ghi rõ `@Library('ci-lib@…')`; nhìn `Jenkinsfile` là biết dùng phiên bản nào |
| `defaultVersion` | Dùng khi app ghi `@Library('ci-lib') _` không kèm phiên bản |
| `allowVersionOverride: true` | Cho phép app ghim phiên bản (`@v1.0.0`) hoặc thử nhánh tính năng (`@feature/x`) |
| `includeInChangesets: false` | Commit của thư viện không hiện trong "Changes" của từng app |
| `credentialsId` | Token GitLab đã có (tạo trong group `devops`), quyền `read_repository` là đủ |

Áp dụng:

```bash
helm upgrade jenkins ./helm-install/jenkins/jenkins -n jenkins -f ./helm-install/jenkins/jenkins/values.yaml -f ./helm-install/jenkins/jenkins/values-build-logs.yaml
```

(Bỏ `-f values-build-logs.yaml` nếu chưa áp dụng phần lưu log, mục [5.14](05-huong-dan-trien-khai.md#514-lưu-trữ-log-build-lên-s3).)

Sidecar `config-reload` nạp lại JCasC khi ConfigMap đổi, không cần khởi động lại Jenkins. Kiểm tra: **Manage Jenkins → System → Global Trusted Pipeline Libraries** có `ci-lib`, hoặc:

```bash
kubectl -n jenkins exec jenkins-0 -c jenkins -- ls /var/jenkins_home/casc_configs/
kubectl -n jenkins logs jenkins-0 -c config-reload --tail=5
```

### Bước 3. Nexus cho Python và Node.js

Các app Maven dùng các repo đã có. Python và Node.js cần thêm `pypi-proxy/hosted/group` và `npm-proxy/hosted/group`, đồng thời `ci-role` cần quyền trên các repo này. Script bootstrap đã được bổ sung phần này:

```bash
ROTATE_CI_PASSWORD=no ./helm-install/nexus/bootstrap.sh
```

`ROTATE_CI_PASSWORD=no` chỉ thêm repo và cập nhật quyền của `ci-role`, giữ nguyên mật khẩu `ci-jenkins`, nên không phải khởi động lại Jenkins. Kiểm tra trên giao diện Nexus: **Repositories** có `npm-group` và `pypi-group`.

| Repo | Loại | Dùng cho |
|---|---|---|
| `npm-proxy` → registry.npmjs.org, `npm-hosted`, `npm-group` | npm | `npm ci` đọc `npm-group`; `npm publish` ghi `npm-hosted` |
| `pypi-proxy` → pypi.org, `pypi-hosted`, `pypi-group` | PyPI | `pip install` đọc `pypi-group/simple`; `twine upload` ghi `pypi-hosted` |

`*-hosted` dùng `writePolicy: allow_once`: không ghi đè được một phiên bản đã phát hành, giúp đảm bảo tính toàn vẹn của package.

### Bước 4. SonarQube

Không cần cấu hình thêm: server `SonarQube`, token và webhook về Jenkins đã có ([3](03-tich-hop-va-bao-mat.md)). Project được tạo tự động ở lần phân tích đầu tiên, với Quality Gate mặc định "Sonar way".

## 7.7. Quản lý phiên bản thư viện

| Quy tắc | Chi tiết |
|---|---|
| **Semantic versioning** | `vMAJOR.MINOR.PATCH`. PATCH: sửa lỗi, không đổi hành vi. MINOR: thêm tính năng/tham số, tương thích ngược. MAJOR: đổi contract (tên tham số, yêu cầu với repo) |
| **App ghim phiên bản cụ thể** | `@Library('ci-lib@v1.0.0')`. Không dùng `@main` trong production: một commit lỗi ở thư viện sẽ làm hỏng toàn bộ pipeline |
| **Nâng phiên bản có kiểm soát** | Renovate (hoặc script) tạo MR đổi `@v1.0.0` → `@v1.1.0` trong từng repo app; pipeline của MR chính là bài kiểm tra |
| **Changelog** | `CHANGELOG.md` trong repo thư viện; mỗi tag kèm mô tả thay đổi và hướng dẫn nâng cấp nếu là MAJOR |
| **Ngừng hỗ trợ phiên bản cũ** | Giữ 2 MAJOR gần nhất; thông báo trước ít nhất một sprint |

**Quy trình thay đổi thư viện:**

1. Tạo nhánh `feature/<tên>` trong repo thư viện.
2. Thử trên một app mẫu: trong MR của app đó, đổi tạm `@Library('ci-lib@feature/<tên>') _` (nhờ `allowVersionOverride: true`). Hoặc dùng **Replay** trên một build cũ để sửa trực tiếp file của thư viện mà không cần commit.
3. Chạy đủ ba loại app mẫu (Maven, Python, Node.js) cho thay đổi ảnh hưởng chung.
4. MR vào `main`, được nhóm platform duyệt, rồi tạo tag mới.
5. Mọi thay đổi phải qua `gradle test` ([7.12](#712-kiểm-thử-thư-viện)); thêm test cho hành vi mới. Repo thư viện nên có pipeline (Jenkins hoặc GitLab CI, image `gradle:8-jdk21`) chạy `gradle test` trên mỗi MR.

## 7.8. Bảo mật và quản trị (môi trường ngân hàng)

**Thư viện khai báo ở mức global là "trusted"**: code chạy ngoài Groovy sandbox, có toàn quyền trên controller. Vì vậy:

| Rủi ro | Biện pháp |
|---|---|
| Ai sửa được repo thư viện thì chạy được code tuỳ ý trên controller | Protected branch + protected tag, MR bắt buộc 2 người duyệt (nhóm platform), `CODEOWNERS`, chỉ nhóm platform có quyền Maintainer. Đây là thay đổi hệ thống, áp dụng change management (PCI DSS 6.5.1) |
| Team app muốn có thư viện riêng | Khai báo ở **mức folder** (Folder → Pipeline Libraries): thư viện này chạy **trong sandbox** (untrusted), không ảnh hưởng controller |
| Chèn lệnh qua tham số `Jenkinsfile` | `ciConfig.app()` từ chối tham số lạ và kiểm tra giá trị bằng regex trước khi đưa vào shell |
| Lộ secret trong log | Credential chỉ qua `withCredentials` (được che trong log); không nội suy secret trong chuỗi Groovy; file cấu hình Maven/npm chỉ chứa tham chiếu biến môi trường; netrc của pip nằm trong `/tmp` của container |
| Team tắt cổng bảo mật | Quality Gate và Trivy nằm trong thư viện, không có tham số tắt. Ngoại lệ Trivy chỉ có 2 cách: `.trivyignore` (từng CVE, có lý do) và `trivyWaiverUntil` (có ngày hết hạn) |
| Ngoại lệ bị lạm dụng | Thêm `CODEOWNERS` trong mỗi repo app: `Jenkinsfile` và `.trivyignore` cần nhóm Security duyệt. Waiver tối đa 90 ngày theo chính sách; hết hạn thì build tự FAILED |
| Image công cụ bị thay thế (supply chain) | Image ghim phiên bản trong `ciConfig`. Production nên ghim theo digest (`image@sha256:…`) và kéo qua Nexus `docker-group` |
| Đẩy artifact từ nhánh chưa review | Publish và Push chỉ chạy trên `develop`, `release/*`, `main` (nhánh được bảo vệ, phải qua MR) |

Ví dụ `.trivyignore` trong repo app (mỗi dòng có lý do và người duyệt):

```
# CVE-2024-XXXXX: thư viện chỉ dùng trong test, không có trong image runtime. Duyệt: security-team, 2026-11-01, xem lại 2027-02-01
CVE-2024-XXXXX
```

## 7.9. Chuyển `shopping-cart` sang thư viện

`Jenkinsfile` hiện tại khoảng 300 dòng được thay bằng:

```groovy
@Library('ci-lib@v1.0.0') _

mavenPipeline(
  name: 'shopping-cart',
  javaVersion: '8',
  trivyWaiverUntil: '2026-12-31'
)
```

Bản này nằm sẵn trên nhánh `feature/ci-lib` của repo app (GitHub `ci-cd-maven-java-ver1`).

| Hạng mục | Trước | Sau |
|---|---|---|
| Tag image | `<commit>` | `<version>-<commit>` (ví dụ `0.0.1-SNAPSHOT-a1b2c3d`) |
| Trivy với Spring Boot 1.5 | `TRIVY_EXIT_CODE='0'` (không chặn) | Waiver có hạn 2026-12-31: build UNSTABLE, sau ngày đó FAILED nếu chưa nâng Spring Boot |
| Push image từ nhánh tính năng | Có | Không (chỉ `develop`, `release/*`, `main`) |
| SBOM | Không | `sbom.cdx.json` (CycloneDX) lưu cùng báo cáo Trivy |
| Cập nhật GitOps, promote, rollback | Trong `Jenkinsfile` (đang tắt) | Chưa có trong v1.0.0; sẽ thêm `ciGitOps` khi bật CD |

Các bước:

1. Làm xong [7.6](#76-chuẩn-bị-nền-tảng-làm-một-lần).
2. Đẩy nhánh `feature/ci-lib` lên GitLab: `git fetch origin feature/ci-lib`, `git push gitlab origin/feature/ci-lib:refs/heads/feature/ci-lib`. Multibranch quét và build nhánh này (không publish, không push image).
3. So sánh với build cũ: số test, coverage và Quality Gate trên SonarQube, báo cáo Trivy trong artifact.
4. Merge vào `develop`, kiểm tra image `…/dev-backend/shopping-cart:<version>-<commit>` có trên Nexus.

## 7.10. Mở rộng thư viện

| Nhu cầu | Cách làm |
|---|---|
| Ngôn ngữ mới (Go, .NET) | Thêm `vars/ciGo.groovy` với 4 hàm `version`, `build`, `sonar`, `publish`; thêm image vào `ciConfig.images`; thêm nhánh trong `ciPod` và `ciPipeline.lang()`; thêm loại vào danh sách `type` hợp lệ. Phát hành MINOR |
| GitOps (khi bật CD) | Thêm `vars/ciGitOps.groovy` (chuyển hàm `updateGitOps` hiện có trong `Jenkinsfile` của shopping-cart), tham số `gitops: [repo: …, path: …]`, chạy sau Push Image trên nhánh được bảo vệ |
| SBOM | Trong `ciImage.scan`: `trivy image --format cyclonedx --output sbom.json`, lưu artifact, đẩy lên Dependency-Track |
| Ký image | Thêm bước `cosign sign` sau push (key trong AWS KMS) |
| Nexus cho `docker build` | Truyền `--build-arg PIP_INDEX_URL` / `NPM_CONFIG_REGISTRY` khi build image, kết hợp BuildKit secret cho credential |
| Thông báo | Hàm `ciNotify` gọi trong `catch`/`finally` của `ciPipeline` (Slack, MS Teams, email), gửi khi build FAILED trên nhánh được bảo vệ |
| Cache dependency | PVC/EFS dùng chung cho `~/.m2`, `~/.npm`, `~/.cache/pip`, hoặc dựa vào Nexus (đã cache proxy) |

## 7.11. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `No such DSL method 'ciPipeline'` | Thiếu `@Library('ci-lib@…') _` ở đầu file, hoặc thư viện chưa khai báo trong JCasC | Thêm dòng `@Library`; kiểm tra Global Trusted Pipeline Libraries |
| `ERROR: Could not find any definition of libraries [ci-lib@vX]` / lỗi checkout thư viện | Tag không tồn tại, hoặc token GitLab không đọc được repo thư viện | `git ls-remote --tags <repo>`; kiểm tra quyền token trong group `devops` |
| `ciPipeline: unknown parameter(s) [...]` | Sai tên tham số | Sửa theo bảng [7.4](#74-tham-số-của-cipipeline) |
| `java.io.NotSerializableException` khi sửa thư viện | Giữ object không serializable (ví dụ `Matcher`) qua một bước pipeline | Đưa xử lý đó vào hàm `@NonCPS` (như `pyprojectVersion`) |
| `Method code too large` | Một file `vars` quá dài | Tách thành nhiều hàm hoặc nhiều file |
| Python: `pip ... is not a trusted or secure host` hoặc 401 | Thiếu repo `pypi-group`, hoặc `ci-role` thiếu quyền | Chạy lại bootstrap Nexus (mục 7.6 bước 3) |
| Node: `npm ci` lỗi 401 / `E404` | Thiếu `npm-group` hoặc quyền; hoặc repo có `.npmrc` trỏ registry khác | Như trên; bỏ `registry=` trong `.npmrc` của repo |
| Node: `Missing script: "test:ci"` | Repo chưa theo contract | Thêm script `test:ci` (7.5.4) |
| Quality Gate fail: coverage 0% | Không có báo cáo coverage đúng đường dẫn | Maven: JaCoCo `report`; Python: `coverage.xml`; Node: `coverage/lcov.info` |
| Build UNSTABLE với thông báo Trivy waiver | Có HIGH/CRITICAL, waiver còn hạn | Lên kế hoạch nâng thư viện/base image trước ngày hết hạn |
| Sửa thư viện nhưng build vẫn chạy code cũ | App ghim tag cũ | Đúng như thiết kế; tạo tag mới và nâng `@Library` trong app |

## 7.12. Kiểm thử thư viện

Thư viện có bộ unit test chạy được không cần Jenkins:

```bash
cd helm-install/jenkins/shared-library
gradle test
```

| Thành phần | Vai trò |
|---|---|
| `build.gradle` | Groovy 2.4.21 (giống runtime pipeline của Jenkins) + JUnit 4; khai báo `vars/`, `resources/` là input để sửa thư viện thì test chạy lại |
| `test/PipelineHarness.groovy` | Nạp mọi `vars/*.groovy` với các step giả lập (`sh`, `stage`, `podTemplate`, `container`, `withCredentials`, `withSonarQubeEnv`, `waitForQualityGate`, `readMavenPom`, `archiveArtifacts`...), ghi lại lệnh sẽ chạy, container chạy lệnh, stage, file ghi ra, pod YAML |
| `test/CiConfigTest.groovy` | 10 test: giá trị mặc định, nhánh được bảo vệ, chặn tham số lạ, phiên bản Java không hỗ trợ, **chặn chèn lệnh** qua `name`, `dockerfile`, `pomFile`, `mavenGoals`, `mavenArgs` |
| `test/MavenPipelineTest.groovy` | 16 test: đủ 8 stage trên `main`; lệnh Maven/Sonar/deploy đúng container và tham số; Java 8 build JDK 8, Sonar JDK 17; pod trên node CI + dind `--insecure-registry`; nhánh tính năng không publish/push; `pomFile`/`mavenGoals`/`mavenArgs`; version từ parent POM; `settings.xml` không chứa mật khẩu; Quality Gate lỗi dừng build; Trivy chặn, waiver còn hạn → UNSTABLE, waiver hết hạn → FAILED; SBOM; `buildImage: false`; `publish: false` |

Kết quả khi phát triển: **26/26 test đạt**. Đã kiểm chứng test bắt được lỗi: cố ý bỏ `nodeSelector` và luôn coi nhánh là "được bảo vệ" thì 3 test fail.

Giới hạn: harness không mô phỏng CPS (serialize trạng thái pipeline), plugin thật, hay kết nối cụm. Vì vậy mỗi phiên bản vẫn phải chạy thử một build thật (nhánh `feature/ci-lib` của `shopping-cart`) trước khi tag.

