# DevOps tools on EKS (helm CLI)

Jenkins, Nexus, SonarQube and Trivy are installed with the helm CLI from the charts in this folder.
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

## Check

```sh
kubectl get pods -A | grep -E 'jenkins|nexus|sonarqube|trivy'
kubectl get ingress -A
```

All Ingresses must show the same ADDRESS as the GitLab one.
