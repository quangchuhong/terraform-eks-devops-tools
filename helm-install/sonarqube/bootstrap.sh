#!/usr/bin/env bash
# Configure SonarQube for Jenkins, through the Web API on a port-forward:
#   - global analysis token "jenkins" (regenerated on each run), stored only in the
#     Kubernetes secret jenkins/sonarqube-token (key: token)
#   - webhook "jenkins" -> http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/
#     (needed by waitForQualityGate)
#
# Usage: ./helm-install/sonarqube/bootstrap.sh   (asks for the SonarQube admin password)
set -euo pipefail

NS="${NS:-sonarqube}"
PORT="${PORT:-19000}"
URL="http://127.0.0.1:${PORT}"
TOKEN_NAME="jenkins"
WEBHOOK_URL="http://jenkins.jenkins.svc.cluster.local:8080/sonarqube-webhook/"

read -r -s -p "SonarQube admin password: " ADMIN_PASS; echo
AUTH="admin:${ADMIN_PASS}"

kubectl -n "$NS" port-forward svc/sonarqube-sonarqube "${PORT}:9000" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -s "${URL}/api/system/status" | grep -q '"status":"UP"' && break
  sleep 2
done

code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "${URL}/api/authentication/validate")
valid=$(curl -s -u "$AUTH" "${URL}/api/authentication/validate")
echo "$valid" | grep -q '"valid":true' || { echo "Admin login failed (HTTP $code). Change the default admin/admin password in the UI first."; exit 1; }

# Token: revoke the previous one with the same name (no error if absent), then generate
curl -s -o /dev/null -u "$AUTH" -X POST "${URL}/api/user_tokens/revoke" --data-urlencode "name=${TOKEN_NAME}"
resp=$(curl -s -u "$AUTH" -X POST "${URL}/api/user_tokens/generate" \
  --data-urlencode "name=${TOKEN_NAME}" --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN")
TOKEN=$(echo "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "FAIL  token generation: $(echo "$resp" | sed 's/"token":"[^"]*"/"token":"***"/')"; exit 1; }
echo "OK    token ${TOKEN_NAME} generated"

# Webhook: create only if no webhook points to Jenkins yet
if curl -s -u "$AUTH" "${URL}/api/webhooks/list" | grep -q "$WEBHOOK_URL"; then
  echo "EXIST webhook ${WEBHOOK_URL}"
else
  resp=$(curl -s -u "$AUTH" -X POST "${URL}/api/webhooks/create" \
    --data-urlencode "name=jenkins" --data-urlencode "url=${WEBHOOK_URL}")
  echo "$resp" | grep -q '"webhook"' || { echo "FAIL  webhook: $resp"; exit 1; }
  echo "OK    webhook ${WEBHOOK_URL}"
fi

kubectl get namespace jenkins >/dev/null 2>&1 || kubectl create namespace jenkins >/dev/null
kubectl -n jenkins create secret generic sonarqube-token --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Done. Token is in secret jenkins/sonarqube-token"
