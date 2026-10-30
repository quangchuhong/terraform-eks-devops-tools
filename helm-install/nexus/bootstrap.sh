#!/usr/bin/env bash
# Configure a fresh Nexus for the CI/CD pipelines, through the REST API on a port-forward:
#   - Docker Bearer Token realm
#   - docker-hosted (8000), docker-proxy -> Docker Hub (8002), docker-group (8001)
#   - role ci-role + user ci-jenkins (read maven-public/docker-group, deploy maven + docker-hosted)
#   - the ci-jenkins password is generated here and stored only in the Kubernetes secret
#     jenkins/nexus-ci (keys: username, password), for the Jenkins credentials.
# Re-runnable: existing repositories/role/user are kept, the ci-jenkins password is rotated.
#
# Usage: ./helm-install/nexus/bootstrap.sh   (asks for the Nexus admin password)
set -euo pipefail

NS="${NS:-nexus}"
PORT="${PORT:-18081}"
CI_USER="ci-jenkins"
URL="http://127.0.0.1:${PORT}/service/rest"

read -r -s -p "Nexus admin password: " ADMIN_PASS; echo
AUTH="admin:${ADMIN_PASS}"

kubectl -n "$NS" port-forward svc/nexus "${PORT}:8081" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:${PORT}/service/rest/v1/status" && break
  sleep 1
done

# call METHOD PATH [JSON] -> prints "<path>: <http code>", fails on anything but 2xx or "already exists"
call() {
  local method="$1" path="$2" body="${3:-}" code out
  out=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -s -o "$out" -w '%{http_code}' -u "$AUTH" -X "$method" -H 'Content-Type: application/json' -d "$body" "${URL}${path}")
  else
    code=$(curl -s -o "$out" -w '%{http_code}' -u "$AUTH" -X "$method" "${URL}${path}")
  fi
  if [[ "$code" =~ ^2 ]]; then
    echo "OK    $method $path"
  elif [ "$code" = "400" ] && grep -qiE 'already exists|must be unique|duplicate' "$out"; then
    echo "EXIST $method $path"
  else
    echo "FAIL  $method $path -> HTTP $code"; cat "$out"; echo; rm -f "$out"; exit 1
  fi
  rm -f "$out"
}

code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "${URL}/v1/security/realms/active")
[ "$code" = "200" ] || { echo "Admin login failed (HTTP $code)"; exit 1; }

# Realms: keep the active ones, add DockerToken
realms=$(curl -s -u "$AUTH" "${URL}/v1/security/realms/active")
if ! echo "$realms" | grep -q '"DockerToken"'; then
  realms=$(echo "$realms" | tr -d ' \n' | sed 's/]$/,"DockerToken"]/; s/\[,/[/')
fi
call PUT /v1/security/realms/active "$realms"

call POST /v1/repositories/docker/hosted '{
  "name": "docker-hosted", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow"},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8000}
}'

call POST /v1/repositories/docker/proxy '{
  "name": "docker-proxy", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "proxy": {"remoteUrl": "https://registry-1.docker.io", "contentMaxAge": 1440, "metadataMaxAge": 1440},
  "negativeCache": {"enabled": true, "timeToLive": 1440},
  "httpClient": {"blocked": false, "autoBlock": true},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8002},
  "dockerProxy": {"indexType": "HUB"}
}'

call POST /v1/repositories/docker/group '{
  "name": "docker-group", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "group": {"memberNames": ["docker-hosted", "docker-proxy"]},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8001}
}'

call POST /v1/security/roles '{
  "id": "ci-role", "name": "ci-role",
  "description": "Jenkins CI: read maven-public/docker-group, deploy maven-releases/snapshots and docker-hosted",
  "privileges": [
    "nx-repository-view-maven2-maven-public-read",
    "nx-repository-view-maven2-maven-public-browse",
    "nx-repository-view-maven2-maven-releases-*",
    "nx-repository-view-maven2-maven-snapshots-*",
    "nx-repository-view-docker-docker-hosted-*",
    "nx-repository-view-docker-docker-group-read",
    "nx-repository-view-docker-docker-group-browse"
  ],
  "roles": []
}'

CI_PASS=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)
call POST /v1/security/users "{
  \"userId\": \"${CI_USER}\", \"firstName\": \"CI\", \"lastName\": \"Jenkins\",
  \"emailAddress\": \"ci-jenkins@gitlabonlinecom.click\", \"password\": \"${CI_PASS}\",
  \"status\": \"active\", \"roles\": [\"ci-role\"]
}"
# Also covers a re-run, where the user already existed
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT -H 'Content-Type: text/plain' \
  --data "$CI_PASS" "${URL}/v1/security/users/${CI_USER}/change-password")
[[ "$code" =~ ^2 ]] || { echo "FAIL  change-password -> HTTP $code"; exit 1; }
echo "OK    password of ${CI_USER} set"

kubectl get namespace jenkins >/dev/null 2>&1 || kubectl create namespace jenkins >/dev/null
kubectl -n jenkins create secret generic nexus-ci \
  --from-literal=username="$CI_USER" --from-literal=password="$CI_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Done. ${CI_USER} credentials are in secret jenkins/nexus-ci"
