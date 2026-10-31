# DevOps tools on EKS (helm CLI)

Jenkins, Nexus, SonarQube, Trivy and GitLab Runner are installed with the helm CLI from this folder.
GitLab stays in Terraform (`gitlab-helm.tf`).

All web apps share the GitLab ALB (Ingress group `alb-apps`, HTTP 80 only). The
`alb.ingress.kubernetes.io/subnets` value is the same on every Ingress (= `var.subnet_ids`).
Do not add `tags`, `certificate-arn` or `ssl-redirect` to just one Ingress: values that differ
inside one ALB group make the AWS Load Balancer Controller reject the whole group.

DNS: `enable_dns_records = true` in Terraform creates `<app>.gitlabonlinecom.click` -> ALB for every name in `app_hostnames`.

## 0. Terraform (once)

Creates the `sonarqube` database and role on the GitLab RDS, the SonarQube secrets, and moves an
existing Terraform Jenkins release out of state without uninstalling it.

```sh
terraform apply
```

## 1. Jenkins

```sh
helm upgrade --install jenkins ./helm-install/jenkins/jenkins -n jenkins --create-namespace --timeout 15m
kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

URL: http://jenkins.gitlabonlinecom.click (user `admin`)

## 2. Nexus

```sh
helm upgrade --install nexus ./helm-install/nexus/nexus-repository-manager -n nexus --create-namespace --timeout 15m
kubectl apply -f helm-install/nexus/manifests/
kubectl -n nexus exec deploy/nexus -- cat /nexus-data/admin.password; echo
```

URL: http://nexus.gitlabonlinecom.click (user `admin`; the password file is removed after the first login).

Docker repositories: give each one an HTTP connector on the port the Service expects.

| Repository | Type | HTTP port | Host |
|---|---|---|---|
| docker-hosted | hosted | 8000 | docker-internal.gitlabonlinecom.click (push) |
| docker-group | group (hosted + proxy) | 8001 | docker.gitlabonlinecom.click (pull) |
| docker-proxy | proxy -> https://registry-1.docker.io | 8002 | docker-proxy.gitlabonlinecom.click |

Also enable *Security -> Realms -> Docker Bearer Token Realm*. The registries are plain HTTP, so
clients need `insecure-registries` (Docker) or `--tls-verify=false` / `--insecure` (Kaniko/Buildah).

Extra repositories for every technology (Docker proxies for ghcr/quay/k8s/ECR Public/MCR/GCR, Gradle,
Conan, vcpkg, apt, yum, apk, Chocolatey, PowerShell Gallery, cloud CLIs), see `docs/nexus/07-cau-hinh-theo-cong-nghe.md`:

```sh
./helm-install/nexus/repos-extra.sh
```

## 3. SonarQube

```sh
helm upgrade --install sonarqube ./helm-install/sonarqube/sonarqube -n sonarqube --timeout 20m --set jdbcOverwrite.jdbcUrl="$(terraform output -raw sonarqube_jdbc_url)"
```

URL: http://sonarqube.gitlabonlinecom.click (first login `admin` / `admin`, then change it).

## 4. Trivy server

```sh
helm upgrade --install trivy ./helm-install/trivy-scanner/trivy -n trivy --create-namespace
```

In-cluster endpoint for pipelines: `trivy image --server http://trivy.trivy:9090 <image>`.
The Ingress is off because the server has no authentication. Set `trivy.serverToken` before turning it on.

## 5. GitLab Runner

Job pods run on the CI node group `ci_agents` (shared with the Jenkins agents); needs `terraform apply` first.
Create an instance runner in GitLab (Admin > CI/CD > Runners > New instance runner), then store its
`glrt-` token in a Secret (never in a file):

```sh
kubectl create namespace gitlab-runner
read -r -s -p "Runner token (glrt-...): " RUNNER_TOKEN; echo
kubectl -n gitlab-runner create secret generic gitlab-runner-token \
  --from-literal=runner-registration-token="" --from-literal=runner-token="$RUNNER_TOKEN"
unset RUNNER_TOKEN
helm repo add gitlab https://charts.gitlab.io && helm repo update gitlab
helm upgrade --install gitlab-runner gitlab/gitlab-runner --version 0.94.0 \
  -n gitlab-runner -f ./helm-install/gitlab-runner/values.yaml
```

## Check

```sh
kubectl get pods -A | grep -E 'jenkins|nexus|sonarqube|trivy|gitlab-runner'
kubectl get ingress -A
```

All Ingresses must show the same ADDRESS as the GitLab one.
