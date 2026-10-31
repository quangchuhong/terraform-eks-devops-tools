# Xem và kiểm tra cấu hình deploy bằng `helm template`

Các DevOps tool được deploy bằng Helm: Jenkins, Nexus, Trivy, GitLab Runner (helm CLI) và GitLab (Terraform `helm_release`). File `values.yaml` chỉ là đầu vào. Thứ thật sự chạy trên cụm là **các manifest Kubernetes** (StatefulSet, Deployment, Service, Ingress, PVC, ConfigMap, RBAC...) do chart sinh ra từ values. `helm template` sinh lại đúng các manifest đó ngay trên máy, không cần cụm, để đọc, review và so sánh với bản đang chạy.

## Tài liệu theo từng tool

| Tool | Tài liệu manifest |
|---|---|
| Jenkins | [jenkins/08-manifest-helm-template.md](../jenkins/08-manifest-helm-template.md) |
| GitLab | [gitlab/07-manifest-helm-template.md](../gitlab/07-manifest-helm-template.md) |
| GitLab Runner | [ci-agents/gitlab-runner-manifest.md](../ci-agents/gitlab-runner-manifest.md) |
| Nexus | [nexus/08-manifest-helm-template.md](../nexus/08-manifest-helm-template.md) |
| Trivy | [trivy/08-manifest-helm-template.md](../trivy/08-manifest-helm-template.md) |

## 1. Render bằng script

```bash
./helm-install/render.sh
./helm-install/render.sh jenkins nexus
DIFF=1 ./helm-install/render.sh jenkins
```

| Tool | Chart | Values | Ghi chú |
|---|---|---|---|
| `jenkins` | `helm-install/jenkins/jenkins` (local) | `values.yaml` + `values-build-logs.yaml` | Luôn đủ 2 file, giống lệnh `helm upgrade` |
| `nexus` | `helm-install/nexus/nexus-repository-manager` (local) | `values.yaml` trong chart | Script chép thêm `manifests/nexus-docker.yaml` (Docker connector, áp bằng `kubectl`) |
| `trivy` | `helm-install/trivy-scanner/trivy` (local) | `values.yaml` trong chart | |
| `gitlab-runner` | `gitlab/gitlab-runner` 0.94.0 (repo charts.gitlab.io) | `helm-install/gitlab-runner/values.yaml` | |
| `gitlab` | `gitlab/gitlab` 10.5.4 | Đọc lại từ release: `helm -n gitlab get values gitlab` | Values do Terraform ghép (file `helm-chart/gitlab-values.yaml` + khối `yamlencode` trong `gitlab-helm.tf`) |

Kết quả nằm ở `helm-install/rendered/` (đã **gitignore**: chart Jenkins sinh mật khẩu admin ngẫu nhiên vào Secret, và values của GitLab có endpoint hạ tầng). Không commit thư mục này.

## 2. Lệnh `helm template` và các tuỳ chọn quan trọng

```bash
helm template jenkins ./helm-install/jenkins/jenkins -n jenkins \
  -f ./helm-install/jenkins/jenkins/values.yaml \
  -f ./helm-install/jenkins/jenkins/values-build-logs.yaml \
  --kube-version 1.34.0 \
  --api-versions networking.k8s.io/v1/Ingress \
  --api-versions policy/v1/PodDisruptionBudget \
  --api-versions autoscaling/v2/HorizontalPodAutoscaler > jenkins.yaml
```

| Tuỳ chọn | Vì sao cần |
|---|---|
| Tên release (`jenkins`) và `-n <namespace>` | Tên tài nguyên và namespace trong manifest phụ thuộc hai giá trị này; phải giống lúc cài thật |
| `-f` theo đúng thứ tự | File sau ghi đè file trước (giống `helm upgrade`) |
| `--kube-version`, `--api-versions` | `helm template` không kết nối cụm nên không biết cụm hỗ trợ API nào. Chart GitLab dựa vào đó để chọn `networking.k8s.io/v1` cho Ingress; thiếu thì sinh định dạng cũ (`serviceName`/`servicePort`), khác với bản thật |
| `--show-only templates/<file>.yaml` | Chỉ xem một template |
| `--no-hooks`, `--skip-tests` | Bỏ hook (Job chạy trước/sau cài) và Pod test (`helm test`), để so với `helm get manifest` |
| `--set key=value` | Thử nhanh một thay đổi trước khi sửa values |

Những thứ `helm template` **không** làm được như lúc cài thật:

- Hàm `lookup` của chart không đọc được cụm. Ví dụ chart Jenkins giữ mật khẩu admin cũ khi upgrade nhờ `lookup`; còn `helm template` mỗi lần sinh mật khẩu mới. Vì vậy **không dùng output của `helm template` để `kubectl apply`**.
- Không kiểm tra manifest với API server. Muốn kiểm tra: `kubectl apply --dry-run=server -f <file>` (cần quyền vào cụm).

## 3. Đọc manifest: những gì cần xem

| Tài nguyên | Xem gì |
|---|---|
| **StatefulSet / Deployment** | `replicas` (hoặc HPA quản lý), `image` + tag, `resources` (requests/limits), `securityContext` (non-root, readOnlyRootFilesystem, capabilities), probe, `volumeMounts` ↔ `volumes`, `serviceAccountName`, `nodeSelector`/`tolerations`, init container |
| **Service** | Cổng, `targetPort`, selector |
| **Ingress** | Host, đường dẫn, Service đích, annotation ALB (group, subnets, listen-ports, health check). Các Ingress trong group `alb-apps` phải có annotation chung giống nhau |
| **PVC / volumeClaimTemplates** | StorageClass, dung lượng, access mode. PVC độc lập thì sửa được qua values; `volumeClaimTemplates` của StatefulSet thì không |
| **ConfigMap** | Cấu hình ứng dụng thật sự được nạp (JCasC, `config.toml`, `gitlab.yml`...) |
| **Secret** | Chỉ xem tên và key (giá trị trong render là mẫu/ngẫu nhiên) |
| **ServiceAccount** | Annotation IRSA `eks.amazonaws.com/role-arn` |
| **Role / RoleBinding** | Quyền của ứng dụng trong cụm (tối thiểu) |
| **HPA / PDB** | Số pod tối thiểu/tối đa, ngưỡng CPU; số pod được phép gián đoạn khi bảo trì node |
| **Hook (Job, Pod test)** | Chạy khi nào (`helm.sh/hook`), có ảnh hưởng dữ liệu không |

Lệnh nhanh để liệt kê tài nguyên:

```bash
yq -N '.kind + " " + .metadata.name' helm-install/rendered/jenkins.yaml
yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | {"name": .name, "image": .image, "resources": .resources}' helm-install/rendered/jenkins.yaml
```

## 4. So sánh với bản đang chạy (phát hiện drift)

```bash
DIFF=1 ./helm-install/render.sh jenkins nexus trivy gitlab-runner gitlab
```

Script render lại không có hook/test, lấy `helm get manifest` của release đang chạy, **bỏ Secret ở cả hai phía** (bản đang chạy chứa mật khẩu thật), rồi `diff`. Kết quả `helm-install/rendered/<tool>.diff`:

| Thấy khác | Ý nghĩa |
|---|---|
| Không khác | Repo và cụm khớp nhau |
| Khác ở values (image tag, resources...) | Có thay đổi trong repo chưa `helm upgrade`, hoặc ngược lại có người upgrade bằng values khác |
| Khác do phiên bản chart | Repo đã đổi chart, chưa áp dụng |

Thay đổi bằng `kubectl edit` không nằm trong `helm get manifest`. Muốn thấy cả loại drift này, dùng plugin `helm diff` (`helm diff upgrade ...`) hoặc `kubectl diff -f`.

## 5. Quy trình review thay đổi values

1. Sửa values trên nhánh, chạy `./helm-install/render.sh <tool>` trước và sau khi sửa, `diff` hai bản (hoặc `helm diff upgrade` nếu có quyền vào cụm).
2. Đưa phần diff manifest vào mô tả MR để người review thấy thay đổi thật trên cụm (ví dụ thay đổi `resources`, thêm sidecar, đổi annotation Ingress).
3. Kiểm tra theo checklist: image ghim phiên bản; non-root; có requests/limits; không thêm quyền RBAC thừa; annotation Ingress giống các Ingress khác trong group; không có secret dạng rõ trong ConfigMap/values.
4. Merge rồi mới `helm upgrade` (hoặc `terraform apply` với GitLab).

Có thể chạy thêm công cụ kiểm tra tĩnh trên output:

```bash
trivy config helm-install/rendered/
kubeconform -kubernetes-version 1.34.0 -summary helm-install/rendered/jenkins.yaml
```

## 6. Kết quả render hiện tại (31/10/2026)

| Tool | Số tài nguyên | Ghi chú chính |
|---|---|---|
| Jenkins | 18 (gồm 1 Pod test) | StatefulSet 3 container: `jenkins`, `config-reload`, `build-log-archiver`; requests rất thấp so với heap (xem tài liệu Jenkins) |
| Nexus | 7 (gồm 2 Pod test) + 4 từ `nexus-docker.yaml` | Deployment `Recreate`; template của chart có một ký tự tab thừa cuối dòng `mountPath` (Kubernetes chấp nhận, một số trình đọc YAML như PyYAML báo lỗi) |
| Trivy | 7 | Chart báo `deprecated`; Secret có `TRIVY_TOKEN` rỗng (server không xác thực) |
| GitLab Runner | 5 | Deployment manager + Role tối thiểu; `config.template.toml` đúng như values |
| GitLab | 61 (gồm 3 hook/test) | Job migrations sinh ra trùng tên với Job đã chạy trên cụm (`gitlab-migrations-cb3b542`): render khớp bản đang chạy |
