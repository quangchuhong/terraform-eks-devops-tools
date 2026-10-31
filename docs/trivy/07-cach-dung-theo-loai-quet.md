# 7. Cách dùng Trivy theo loại quét

[← Mục lục Trivy](README.md)

Trong cụm, thêm `--server http://trivy.trivy.svc.cluster.local:9090` cho các lệnh quét lỗ hổng để dùng DB của server. Máy cá nhân chạy standalone (tự tải DB).

## 7.1. Image

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed docker.gitlabonlinecom.click/library/nginx:1.27
trivy image --input image.tar --format json --output report.json
trivy image --format table --pkg-types os docker-internal.gitlabonlinecom.click/dev-backend/shopping-cart:<tag>
```

Registry riêng (Nexus): `TRIVY_USERNAME`, `TRIVY_PASSWORD`; registry HTTP thêm `TRIVY_INSECURE=true`.

GitLab CI:

```yaml
trivy-image:
  tags: [eks]
  image:
    name: aquasec/trivy:0.68.2
    entrypoint: [""]
  variables:
    TRIVY_USERNAME: $NEXUS_USER
    TRIVY_PASSWORD: $NEXUS_PASSWORD
    TRIVY_INSECURE: "true"
  script:
    - trivy image --server http://trivy.trivy.svc.cluster.local:9090 --exit-code 0 --format template --template "@/contrib/gitlab.tpl" --output gl-container-scanning-report.json docker-internal.gitlabonlinecom.click/dev-backend/$CI_PROJECT_NAME:$CI_COMMIT_SHORT_SHA
    - trivy image --server http://trivy.trivy.svc.cluster.local:9090 --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed docker-internal.gitlabonlinecom.click/dev-backend/$CI_PROJECT_NAME:$CI_COMMIT_SHORT_SHA
  artifacts:
    reports:
      container_scanning: gl-container-scanning-report.json
```

## 7.2. Mã nguồn và thư viện (filesystem, repo)

```bash
trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL .
trivy repo http://gitlab.gitlabonlinecom.click/devops/ci-cd/shopping-cart.git
```

Trivy đọc file khoá phụ thuộc: `pom.xml`, `gradle.lockfile`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements.txt`, `poetry.lock`, `Pipfile.lock`, `go.sum`, `Cargo.lock`, `packages.lock.json` (.NET), `conan.lock`... Kết quả chính xác hơn khi có lock file (phiên bản cụ thể của cả phụ thuộc bắc cầu). Với Maven không có lock file, quét **sau khi build** (jar trong `target/` hoặc image) cho kết quả đầy đủ hơn.

## 7.3. SBOM

```bash
trivy image --format cyclonedx --output sbom.cdx.json <image>
trivy image --format spdx-json --output sbom.spdx.json <image>
trivy fs --format cyclonedx --output sbom.cdx.json .
trivy sbom --severity HIGH,CRITICAL sbom.cdx.json
```

Quét lại SBOM cũ (`trivy sbom`) để biết phiên bản đã phát hành có bị ảnh hưởng bởi CVE mới không, không cần image.

## 7.4. IaC (Terraform, Kubernetes, Helm, Dockerfile)

```bash
trivy config --severity HIGH,CRITICAL .
trivy config --tf-vars terraform.tfvars ./terraform-eks-devops-tools
trivy config helm-install/jenkins/jenkins
trivy config --helm-values helm-install/jenkins/jenkins/values.yaml helm-install/jenkins/jenkins
trivy config Dockerfile
```

Phát hiện ví dụ: S3 không mã hoá/public, security group mở `0.0.0.0/0`, RDS không bật deletion protection, container chạy root/privileged (sẽ báo `docker:dind`), thiếu resource limit, Dockerfile dùng `latest` hoặc không có `USER`.

Bỏ qua một phát hiện có chủ ý ngay trong mã:

```hcl
#trivy:ignore:AVD-AWS-0057
resource "aws_iam_role_policy" "example" { ... }
```

## 7.5. Secret

```bash
trivy fs --scanners secret .
trivy image --scanners secret <image>
```

Phát hiện khoá AWS, token GitHub/GitLab, private key, mật khẩu trong file cấu hình... Nên chạy ở MR (repo) và với image phát hành. Tuỳ chỉnh/loại trừ bằng `trivy-secret.yaml` (`--secret-config`). Gặp secret thật: **xoay vòng secret** trước, sau đó mới gỡ khỏi mã.

## 7.6. License

```bash
trivy image --scanners license --severity HIGH,CRITICAL <image>
trivy fs --scanners license --license-full .
```

Trivy phân loại license theo nhóm (forbidden, restricted, reciprocal, notice, permissive...); chặn nhóm `forbidden`/`restricted` (ví dụ AGPL cho phần mềm phân phối). Cho yêu cầu pháp chế chặt (nghĩa vụ license, notice file, snippet), xem [Black Duck](04-so-sanh-trivy-blackduck.md).

## 7.7. Cụm Kubernetes

```bash
trivy k8s --report summary
trivy k8s --include-namespaces jenkins,nexus,gitlab --severity HIGH,CRITICAL --report all
trivy k8s --compliance k8s-cis-1.23 --report summary
```

Quét cả image đang chạy, cấu hình workload (privileged, hostPath, thiếu limit...), RBAC. Dùng cho đợt quét định kỳ (PCI DSS 11.3.1); quét liên tục dùng Trivy Operator ([6.4](06-van-hanh-va-tu-dong-hoa.md#64-quét-liên-tục-trong-cụm-trivy-operator)).

## 7.8. Máy ảo, AMI, root filesystem

```bash
trivy rootfs /
trivy vm --scanners vuln ami:ami-0123456789abcdef0
```

Dùng để quét AMI dựng sẵn (golden image) trước khi đưa vào node group, hoặc quét máy chủ Linux ngoài Kubernetes.
