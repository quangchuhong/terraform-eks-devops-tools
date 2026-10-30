# Jenkins từ chart đã vendor trong repo (helm-install/jenkins/jenkins).
# Truy cập: http://jenkins.<domain> (ALB dùng chung group alb-apps, bản ghi DNS ở gitlab-helm.tf).
# Mật khẩu admin: kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
resource "helm_release" "jenkins" {
  name             = "jenkins"
  chart            = "${path.module}/helm-install/jenkins/jenkins"
  namespace        = "jenkins"
  create_namespace = true

  values = [
    file("${path.module}/helm-chart/jenkins-values.yaml"),
    yamlencode({
      controller = {
        jenkinsUrl = "http://jenkins.${var.domain}"
        ingress = {
          hostName = "jenkins.${var.domain}"
          annotations = {
            "alb.ingress.kubernetes.io/subnets" = join(", ", var.subnet_ids)
          }
        }
      }
    })
  ]

  timeout = 900 # lần đầu tải plugin có thể lâu

  depends_on = [
    module.eks, helm_release.lb_controller, kubernetes_storage_class.gp3
  ]
}
