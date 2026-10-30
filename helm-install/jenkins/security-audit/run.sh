#!/usr/bin/env bash
# Runs audit.groovy in the Jenkins script console from inside the controller pod.
# The admin password is read from the pod's own secret mount and never printed.
set -euo pipefail
cd "$(dirname "$0")"
NS="${NS:-jenkins}"
POD="${POD:-jenkins-0}"

kubectl -n "$NS" exec -i "$POD" -c jenkins -- sh -c 'cat > /tmp/audit.groovy' < audit.groovy
kubectl -n "$NS" exec "$POD" -c jenkins -- sh -c '
  U=$(cat /run/secrets/additional/chart-admin-username)
  P=$(cat /run/secrets/additional/chart-admin-password)
  CRUMB=$(curl -sf -c /tmp/cj -u "$U:$P" "http://localhost:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
  curl -sf -b /tmp/cj -u "$U:$P" -H "$CRUMB" --data-urlencode "script@/tmp/audit.groovy" http://localhost:8080/scriptText
  rm -f /tmp/cj /tmp/audit.groovy
'
