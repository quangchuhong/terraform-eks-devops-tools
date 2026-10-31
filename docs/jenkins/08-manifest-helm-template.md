# 8. Manifest Jenkins sinh từ `helm template`

[← Mục lục Jenkins](README.md) · [Hướng dẫn chung về `helm template`](../helm-template/README.md)

## 8.1. Render

```bash
./helm-install/render.sh jenkins
```

Tương đương:

```bash
helm template jenkins ./helm-install/jenkins/jenkins -n jenkins \
  -f ./helm-install/jenkins/jenkins/values.yaml \
  -f ./helm-install/jenkins/jenkins/values-build-logs.yaml \
  --kube-version 1.34.0 --api-versions networking.k8s.io/v1/Ingress > helm-install/rendered/jenkins.yaml
```

## 8.2. Danh sách tài nguyên (18)

| Kind | Tên | Vai trò | Sinh từ values |
|---|---|---|---|
| ServiceAccount | `jenkins` | Danh tính của controller; annotation IRSA `eks.amazonaws.com/role-arn: ...:role/eks-cluster-ver1-jenkins-artifacts` | `serviceAccount.annotations` |
| Secret | `jenkins` | `jenkins-admin-user`, `jenkins-admin-password` (user `admin` của JCasC) | `controller.admin.*` (mật khẩu: chart giữ giá trị cũ khi upgrade nhờ `lookup`) |
| ConfigMap | `jenkins` | `apply_config.sh` (script của init container), `plugins.txt` (127 plugin ghim phiên bản) | `controller.installPlugins` |
| ConfigMap | `jenkins-jenkins-jcasc-config` | JCasC mặc định của chart: cloud Kubernetes, template agent, location URL, security | `controller.JCasC.defaultConfig`, `agent.*`, `controller.jenkinsUrl` |
| ConfigMap | `jenkins-jenkins-config-ci-integrations` | Credentials (`nexus-creds`, `docker-user-internal`, `sonarqube-token`, `gitlab-token-dev-group`) + server SonarQube | `controller.JCasC.configScripts.ci-integrations` |
| ConfigMap | `jenkins-jenkins-config-artifact-s3` | Artifact manager S3 (bucket, prefix, region) | `configScripts.artifact-s3` |
| ConfigMap | `jenkins-jenkins-config-welcome-message` | Thông báo trên giao diện | `configScripts.welcome-message` |
| PersistentVolumeClaim | `jenkins` | `JENKINS_HOME`, gp3, **50Gi**, RWO (PVC độc lập, không phải `volumeClaimTemplates`) | `persistence.*` |
| Role + RoleBinding | `jenkins-schedule-agents` | Tạo/xoá pod agent trong namespace `jenkins` (pods, pods/exec, pods/log, PVC, events) | `rbac.create` |
| Role + RoleBinding | `jenkins-casc-reload` / `jenkins-watch-configmaps` | Sidecar đọc ConfigMap JCasC (`get`, `watch`, `list`) | `controller.sidecars.configAutoReload` |
| Service | `jenkins` | ClusterIP `8080` (giao diện, API) | `controller.servicePort` |
| Service | `jenkins-agent` | ClusterIP `50000` (agent kết nối inbound) | `controller.agentListenerPort` |
| StatefulSet | `jenkins` | Controller (1 replica) | `controller.*` |
| Ingress | `jenkins` | `jenkins.gitlabonlinecom.click` → `jenkins:8080`, ALB group `alb-apps`, health check `/login` | `controller.ingress.*` |
| ConfigMap + Pod | `jenkins-tests`, `jenkins-ui-test-*` | Test của chart, chỉ chạy khi `helm test jenkins` (hook `test`) | Chart |

Không có Secret nào cho credentials của Nexus, SonarQube, GitLab: chart chỉ **tham chiếu** các Secret có sẵn (`nexus-ci`, `sonarqube-token`, `gitlab-ci`) qua `controller.additionalExistingSecrets`. Các Secret này tạo trước bằng `bootstrap.sh` hoặc `kubectl`.

## 8.3. StatefulSet `jenkins`

```
StatefulSet jenkins (replicas 1, serviceName jenkins)
  securityContext: runAsUser 1000, fsGroup 1000, fsGroupChangePolicy OnRootMismatch, runAsNonRoot
  serviceAccountName: jenkins          enableServiceLinks: false
  initContainers:
    config-reload-init  kiwigrid/k8s-sidecar:1.30.7     tải ConfigMap JCasC lần đầu vào casc_configs
    init                jenkins/jenkins:2.580.2-jdk21    apply_config.sh: tắt Setup Wizard, cài 127 plugin từ plugins.txt
  containers:
    jenkins             jenkins/jenkins:2.580.2-jdk21    cổng 8080 (http), 50000 (agent)
    config-reload       kiwigrid/k8s-sidecar:1.30.7     theo dõi ConfigMap có label jenkins-jenkins-config, gọi reload JCasC
    build-log-archiver  amazon/aws-cli:2.38.1           sidecar lưu log build lên S3 (values-build-logs.yaml)
```

### Container `jenkins`

| Thuộc tính | Giá trị render | Từ values |
|---|---|---|
| Image | `docker.io/jenkins/jenkins:2.580.2-jdk21` | `controller.image.tag` |
| Resources | requests `50m` / `256Mi`, limits `2000m` / `4096Mi` | `controller.resources` |
| Env `JAVA_OPTS` | `-Dcasc.reload.token=$(POD_NAME) -Xms512m -Xmx1024m` | `controller.javaOpts` |
| Env `CASC_JENKINS_CONFIG` | `/var/jenkins_home/casc_configs` | Chart |
| Env `SECRETS` | `/run/secrets/additional` (JCasC đọc `${<secret>-<key>}` từ đây) | Chart |
| Env `JENKINS_OPTS` | `--webroot=/var/jenkins_cache/war` | Chart |
| startupProbe | `GET /login`, mỗi 10 giây, tối đa 30 lần (5 phút cho khởi động) | `controller.probes` |
| liveness / readiness | `GET /login`, mỗi 10 giây, failure 5 / 3 | |
| securityContext | `runAsUser 1000`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` | `controller.containerSecurityContext` |

### Volume và mount

| Volume | Loại | Mount (container `jenkins`) | Nội dung |
|---|---|---|---|
| `jenkins-home` | PVC `jenkins` | `/var/jenkins_home` | Job, build, log, cấu hình (sidecar log mount chỉ đọc) |
| `jenkins-config` | ConfigMap `jenkins` | `/var/jenkins_config` | `apply_config.sh`, `plugins.txt` |
| `plugin-dir` | emptyDir | `/usr/share/jenkins/ref/plugins/` | Plugin do init container tải |
| `sc-config-volume` | emptyDir | `/var/jenkins_home/casc_configs` | File JCasC (sidecar ghi, Jenkins đọc) |
| `jenkins-secrets` | **projected** | `/run/secrets/additional` | `nexus-ci-username/password`, `sonarqube-token-token`, `gitlab-ci-username/token`, `chart-admin-username/password` |
| `jenkins-cache` | emptyDir | `/var/jenkins_cache` | WAR giải nén |
| `tmp-volume` | emptyDir | `/tmp` | Vì root filesystem chỉ đọc |
| `build-log-state`, `build-log-tmp` | emptyDir | (sidecar) `/state`, `/tmp` | Trạng thái của sidecar lưu log |

Projected volume `jenkins-secrets` gom nhiều Secret vào một thư mục, mỗi key thành một file tên `<secret>-<key>`. JCasC dùng `${nexus-ci-password}` để đọc file đó, nên mật khẩu không nằm trong ConfigMap hay biến môi trường.

## 8.4. Cấu hình agent trong JCasC (ConfigMap `jenkins-jenkins-jcasc-config`)

```yaml
clouds:
  - kubernetes:
      name: "kubernetes"
      namespace: "jenkins"
      jenkinsUrl: "http://jenkins.jenkins.svc.cluster.local:8080"
      jenkinsTunnel: "jenkins-agent.jenkins.svc.cluster.local:50000"
      containerCapStr: "10"
      templates:
        - name: "default"
          label: "jenkins-jenkins-agent default"
          nodeSelector: workload=ci-agents
          containers:
          - name: "jnlp"
            image: "jenkins/inbound-agent:3355.v388858a_47b_33-3-jdk21"
            resourceRequestCpu: 512m
            resourceRequestMemory: 512Mi
          yaml: |-
            spec:
              tolerations:
                - key: workload
                  operator: Equal
                  value: ci-agents
                  effect: NoSchedule
```

- `containerCapStr: "10"`: tối đa 10 pod agent cùng lúc từ cloud này (`agent.containerCap`).
- Agent kết nối controller qua Service trong cụm, không qua ALB.
- Template `default` chạy trên node CI. Pipeline tự định nghĩa `podTemplate` (như `shopping-cart`) phải tự khai báo `nodeSelector` + toleration ([CI agents 2.3](../ci-agents/README.md#23-cơ-chế-đặt-pod-lên-node-ci)).

## 8.5. Nhận xét từ manifest

| # | Phát hiện | Mức | Đề xuất |
|---|---|---|---|
| 1 | Requests của container `jenkins` là `50m` CPU / `256Mi`, trong khi heap tối đa `-Xmx1024m` và limit 4Gi | Trung bình | Scheduler xếp pod theo requests: pod có thể được đặt lên node gần đầy, rồi bị thiếu bộ nhớ hoặc bị evict khi node chịu áp lực. Đặt requests sát nhu cầu thật, ví dụ `cpu: 500m`, `memory: 2Gi` (mức tải thấp, [2.2](02-sizing.md)) |
| 2 | `config-reload`, `config-reload-init` không có resources | Thấp | Đặt `controller.sidecars.configAutoReload.resources` (ví dụ 10m/64Mi) |
| 3 | Root filesystem chỉ đọc, non-root, không privilege escalation | Tốt | Giữ nguyên |
| 4 | Credentials qua projected Secret, không nằm trong ConfigMap | Tốt | Giữ nguyên |
| 5 | Pod test `jenkins-ui-test-*` có trong render | Thông tin | Chỉ chạy khi `helm test`; `helm upgrade` không tạo pod này |
| 6 | Ingress HTTP, annotation chung với group `alb-apps` | Đã biết | Khi bật HTTPS, sửa đồng loạt các Ingress trong group |

## 8.6. Kiểm tra thay đổi trước khi upgrade

```bash
./helm-install/render.sh jenkins
cp helm-install/rendered/jenkins.yaml /tmp/jenkins-before.yaml
./helm-install/render.sh jenkins
diff -u /tmp/jenkins-before.yaml helm-install/rendered/jenkins.yaml | grep -v 'jenkins-admin-password\|jenkins-ui-test'
DIFF=1 ./helm-install/render.sh jenkins
```

Chạy lệnh render thứ hai sau khi sửa values. Ví dụ đổi `persistence.size` chỉ làm đổi `spec.resources.requests.storage` của PVC `jenkins` (mở rộng online, [5.13](05-huong-dan-trien-khai.md#513-mở-rộng-volume-jenkins_home-khi-gần-đầy)); thêm plugin làm đổi ConfigMap `jenkins` và annotation checksum của StatefulSet (pod khởi động lại).
