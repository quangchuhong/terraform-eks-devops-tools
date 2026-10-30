# Jenkins moved from Terraform to the helm CLI (helm-install/jenkins/jenkins).
# Drop the old helm_release from state without uninstalling it, so an existing
# release is adopted as-is by `helm upgrade --install jenkins ...`.
removed {
  from = helm_release.jenkins
  lifecycle {
    destroy = false
  }
}
