#!/usr/bin/env bash
# Extra Nexus repositories for all technologies (docs/nexus/07-cau-hinh-theo-cong-nghe.md), through the
# REST API on a port-forward. Run after bootstrap.sh. Re-runnable: existing repositories are kept.
#   - Docker: proxies for ghcr.io, quay.io, registry.k8s.io, public.ecr.aws, mcr.microsoft.com, gcr.io,
#     added to docker-group (pulled through docker.<domain>)
#   - Java: Gradle Plugin Portal proxy, added to maven-public
#   - C/C++: conan-proxy (ConanCenter), conan-hosted, raw vcpkg-cache
#   - Linux: apt proxies (Ubuntu, Debian), yum proxies (Rocky, EPEL), raw alpine-proxy
#   - Windows: chocolatey-proxy, psgallery-proxy (NuGet V2); nuget.org-proxy/nuget-group are Nexus defaults
#   - Cloud tools: apt/yum proxies for Azure CLI, Google Cloud CLI, HashiCorp; raw proxies for the AWS CLI
#     and releases.hashicorp.com
#   - raw tools-hosted (internal binaries), role read-all (read/browse every repository)
# docker-group and maven-public are rewritten with the member lists below: add here any member you
# added by hand, or it is removed from the group.
# Failures are reported and the script continues (one unsupported format does not stop the rest).
#
# Usage: ./helm-install/nexus/repos-extra.sh   (asks for the Nexus admin password)
set -uo pipefail

NS="${NS:-nexus}"
PORT="${PORT:-18081}"
URL="http://127.0.0.1:${PORT}/service/rest"
FAILED=0

read -r -s -p "Nexus admin password: " ADMIN_PASS; echo
AUTH="admin:${ADMIN_PASS}"

kubectl -n "$NS" port-forward svc/nexus "${PORT}:8081" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -s -o /dev/null "http://127.0.0.1:${PORT}/service/rest/v1/status" && break
  sleep 1
done

code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "${URL}/v1/security/realms/active")
[ "$code" = "200" ] || { echo "Admin login failed (HTTP $code)"; exit 1; }

# call METHOD PATH [JSON] -> OK / EXIST / FAIL (continues on FAIL)
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
    echo "FAIL  $method $path -> HTTP $code: $(head -c 300 "$out")"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$out"
}

STORAGE='"storage": {"blobStoreName": "default", "strictContentTypeValidation": true}'
COMMON='"negativeCache": {"enabled": true, "timeToLive": 1440}, "httpClient": {"blocked": false, "autoBlock": true}'

# proxy FORMAT NAME REMOTE_URL [EXTRA_JSON]
proxy() {
  local fmt="$1" name="$2" remote="$3" extra="${4:-}"
  call POST "/v1/repositories/${fmt}/proxy" "{
    \"name\": \"${name}\", \"online\": true, ${STORAGE},
    \"proxy\": {\"remoteUrl\": \"${remote}\", \"contentMaxAge\": 1440, \"metadataMaxAge\": 1440},
    ${COMMON}${extra:+, ${extra}}
  }"
}

# hosted FORMAT NAME WRITE_POLICY [EXTRA_JSON]
hosted() {
  local fmt="$1" name="$2" policy="$3" extra="${4:-}"
  call POST "/v1/repositories/${fmt}/hosted" "{
    \"name\": \"${name}\", \"online\": true,
    \"storage\": {\"blobStoreName\": \"default\", \"strictContentTypeValidation\": true, \"writePolicy\": \"${policy}\"}
    ${extra:+, ${extra}}
  }"
}

echo "== Docker proxies (pulled through docker-group)"
DOCKER_PROXY='"docker": {"v1Enabled": false, "forceBasicAuth": true}, "dockerProxy": {"indexType": "REGISTRY", "cacheForeignLayers": false}'
proxy docker ghcr-proxy       https://ghcr.io           "$DOCKER_PROXY"
proxy docker quay-proxy       https://quay.io           "$DOCKER_PROXY"
proxy docker k8s-proxy        https://registry.k8s.io   "$DOCKER_PROXY"
proxy docker ecr-public-proxy https://public.ecr.aws    "$DOCKER_PROXY"
proxy docker gcr-proxy        https://gcr.io            "$DOCKER_PROXY"
# Windows images reference "foreign layers" on Microsoft servers: cache them in Nexus too
proxy docker mcr-proxy        https://mcr.microsoft.com \
  '"docker": {"v1Enabled": false, "forceBasicAuth": true}, "dockerProxy": {"indexType": "REGISTRY", "cacheForeignLayers": true, "foreignLayerUrlWhitelist": [".*"]}'

call PUT /v1/repositories/docker/group/docker-group '{
  "name": "docker-group", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "group": {"memberNames": ["docker-hosted", "docker-proxy", "ghcr-proxy", "quay-proxy", "k8s-proxy", "ecr-public-proxy", "gcr-proxy", "mcr-proxy"]},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8001}
}'

echo "== Java / Gradle"
proxy maven2 gradle-plugins-proxy https://plugins.gradle.org/m2/ \
  '"maven": {"versionPolicy": "RELEASE", "layoutPolicy": "PERMISSIVE"}'
call PUT /v1/repositories/maven/group/maven-public '{
  "name": "maven-public", "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "group": {"memberNames": ["maven-releases", "maven-snapshots", "maven-central", "gradle-plugins-proxy"]}
}'

echo "== C / C++"
proxy conan conan-proxy https://center2.conan.io '"conanProxy": {"conanVersion": "V2"}'
hosted conan conan-hosted allow_once
hosted raw vcpkg-cache allow '"raw": {"contentDisposition": "ATTACHMENT"}'

echo "== Linux packages"
apt_proxy() { proxy apt "$1" "$2" "\"apt\": {\"distribution\": \"$3\", \"flat\": false}"; }
apt_proxy ubuntu-proxy          http://archive.ubuntu.com/ubuntu/   noble
apt_proxy ubuntu-security-proxy http://security.ubuntu.com/ubuntu/  noble
apt_proxy debian-proxy          http://deb.debian.org/debian/       bookworm
apt_proxy debian-security-proxy http://deb.debian.org/debian-security/ bookworm
proxy yum rocky-proxy https://dl.rockylinux.org/pub/rocky/
proxy yum epel-proxy  https://dl.fedoraproject.org/pub/epel/
proxy raw alpine-proxy https://dl-cdn.alpinelinux.org/alpine/ '"raw": {"contentDisposition": "ATTACHMENT"}'

echo "== Windows"
proxy nuget chocolatey-proxy https://community.chocolatey.org/api/v2/ '"nugetProxy": {"queryCacheItemMaxAge": 3600, "nugetVersion": "V2"}'
proxy nuget psgallery-proxy  https://www.powershellgallery.com/api/v2/ '"nugetProxy": {"queryCacheItemMaxAge": 3600, "nugetVersion": "V2"}'

echo "== Cloud CLIs and tools"
apt_proxy azure-cli-apt-proxy  https://packages.microsoft.com/repos/azure-cli/ noble
apt_proxy google-cloud-apt-proxy https://packages.cloud.google.com/apt/        cloud-sdk
apt_proxy hashicorp-apt-proxy  https://apt.releases.hashicorp.com/             noble
proxy yum azure-cli-yum-proxy    https://packages.microsoft.com/yumrepos/azure-cli/
proxy yum google-cloud-yum-proxy https://packages.cloud.google.com/yum/
proxy yum hashicorp-yum-proxy    https://rpm.releases.hashicorp.com/
proxy raw awscli-proxy             https://awscli.amazonaws.com/    '"raw": {"contentDisposition": "ATTACHMENT"}'
proxy raw hashicorp-releases-proxy https://releases.hashicorp.com/  '"raw": {"contentDisposition": "ATTACHMENT"}'

echo "== Internal binaries"
hosted raw tools-hosted allow_once '"raw": {"contentDisposition": "ATTACHMENT"}'

echo "== Role read-all (read + browse on every repository)"
call POST /v1/security/roles '{
  "id": "read-all", "name": "read-all",
  "description": "Read and browse every repository (developers, build machines)",
  "privileges": ["nx-repository-view-*-*-read", "nx-repository-view-*-*-browse"],
  "roles": []
}'

echo
if [ "$FAILED" -gt 0 ]; then
  echo "Done with $FAILED failure(s): see FAIL lines above (format not available in this Nexus version, or bad remote)."
  exit 1
fi
echo "Done."
