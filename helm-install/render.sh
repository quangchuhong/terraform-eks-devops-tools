#!/usr/bin/env bash
# Render the Kubernetes manifests of the DevOps tools with `helm template`, with the same charts and
# values as the real deployment, to review them (docs/helm-template/README.md).
#   ./helm-install/render.sh                       all tools
#   ./helm-install/render.sh jenkins nexus         some tools
#   DIFF=1 ./helm-install/render.sh jenkins        also diff against what is deployed (helm get manifest)
# Output: helm-install/rendered/<tool>.yaml (git-ignored: the Jenkins chart renders a random admin
# password into a Secret, and GitLab values contain account endpoints).
#
# GitLab is installed by Terraform: its values are read back from the release (helm get values), so
# the render matches exactly what Terraform passed (helm-chart/gitlab-values.yaml + yamlencode block).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=helm-install/rendered
mkdir -p "$OUT"
# Capabilities of the EKS cluster: without them some charts (GitLab) pick old API versions
KUBE=(--kube-version 1.34.0
  --api-versions networking.k8s.io/v1/Ingress
  --api-versions policy/v1/PodDisruptionBudget
  --api-versions autoscaling/v2/HorizontalPodAutoscaler)
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-10.5.4}"
RUNNER_CHART_VERSION="${RUNNER_CHART_VERSION:-0.94.0}"

# Remove "kind: Secret" documents from a multi-document YAML stream
drop_secrets() {
  awk 'BEGIN{RS="\n---"; ORS="\n---"} !/\nkind: Secret\n/ && !/^kind: Secret\n/'
}

need_gitlab_repo() {
  helm repo list 2>/dev/null | grep -q '^gitlab\s' || helm repo add gitlab https://charts.gitlab.io >/dev/null
  helm repo update gitlab >/dev/null
}

render() {
  local tool="$1" ns="$2"
  shift 2
  helm template "$tool" "$@" -n "$ns" "${KUBE[@]}" > "$OUT/$tool.yaml"
  echo "rendered $OUT/$tool.yaml ($(grep -c '^kind:' "$OUT/$tool.yaml") resources)"
  if [ "${DIFF:-0}" = "1" ]; then
    if helm -n "$ns" status "$tool" >/dev/null 2>&1; then
      # helm get manifest has no hooks/tests: render again without them. Secrets are dropped from
      # both sides (the deployed ones hold real passwords, the rendered ones random values).
      helm template "$tool" "$@" -n "$ns" "${KUBE[@]}" --no-hooks --skip-tests | drop_secrets > "$OUT/$tool.nohooks.yaml"
      helm -n "$ns" get manifest "$tool" | drop_secrets > "$OUT/$tool.deployed.yaml"
      if diff -u "$OUT/$tool.deployed.yaml" "$OUT/$tool.nohooks.yaml" > "$OUT/$tool.diff"; then
        echo "  no difference with the deployed release"
      else
        echo "  differences: $OUT/$tool.diff ($(grep -c '^[-+][^-+]' "$OUT/$tool.diff") lines)"
      fi
    else
      echo "  release $tool not found in namespace $ns, no diff"
    fi
  fi
}

TOOLS=("$@")
[ ${#TOOLS[@]} -eq 0 ] && TOOLS=(jenkins nexus trivy gitlab-runner gitlab)

for t in "${TOOLS[@]}"; do
  case "$t" in
    jenkins)
      render jenkins jenkins ./helm-install/jenkins/jenkins \
        -f ./helm-install/jenkins/jenkins/values.yaml -f ./helm-install/jenkins/jenkins/values-build-logs.yaml ;;
    nexus)
      render nexus nexus ./helm-install/nexus/nexus-repository-manager
      cp helm-install/nexus/manifests/nexus-docker.yaml "$OUT/nexus-docker.yaml"
      echo "  + $OUT/nexus-docker.yaml (plain manifest, applied with kubectl)" ;;
    trivy)
      render trivy trivy ./helm-install/trivy-scanner/trivy ;;
    gitlab-runner)
      need_gitlab_repo
      render gitlab-runner gitlab-runner gitlab/gitlab-runner --version "$RUNNER_CHART_VERSION" \
        -f ./helm-install/gitlab-runner/values.yaml ;;
    gitlab)
      need_gitlab_repo
      helm -n gitlab get values gitlab > "$OUT/gitlab.values.yaml"
      render gitlab gitlab gitlab/gitlab --version "$GITLAB_CHART_VERSION" -f "$OUT/gitlab.values.yaml" ;;
    *)
      echo "unknown tool: $t (jenkins nexus trivy gitlab-runner gitlab)"; exit 1 ;;
  esac
done
