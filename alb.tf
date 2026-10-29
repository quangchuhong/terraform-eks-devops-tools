# Create the Application Load Balancer (ALB)
/*
resource "aws_security_group" "alb_sg" {
  vpc_id = var.vpc_id
  name   = "alb-security-group"
  description = "Allow HTTP/HTTPS traffic to ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "main_alb" {
  name               = "alb-apps"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.subnet_ids

  tags = {
    Name = "main-alb"
  }
}


resource "kubernetes_ingress_v1" "gitlab_ingress" {
  metadata {
    name      = "gitlab-ingress"
    namespace = "gitlab"
    annotations = {
      "alb.ingress.kubernetes.io/group.name" = "my-ingress-group"  # 👈 Tên group
      "alb.ingress.kubernetes.io/scheme"    = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
    }
  }
  dêpn
}


# Tạo Route53 A Record alias đến ALB

variable "route53_zone_id" {
  type        = string
  description = "Route53 Hosted Zone ID (ví dụ: Z1ABC234DEFG56)"
  default     = "Z08613522NHM48MOSOSYV"
}


resource "aws_route53_record" "alb_git_alias" {
  zone_id = var.route53_zone_id  # ID của Hosted Zone trong Route53
  name    = "gitlab.gitlabonlinecom.click"  # 👈 Thay domain của bạn
  type    = "A"

  alias {
    name                   = "dualstack.${aws_lb.main_alb.dns_name}"  # DNS name của ALB
    zone_id                = aws_lb.main_alb.zone_id   # Zone ID của ALB
    evaluate_target_health = true  # Kiểm tra health check của ALB
  }
  depends_on = [ aws_lb.main_alb ]
}


resource "aws_route53_record" "alb_grafana_alias" {
  zone_id = var.route53_zone_id  # ID của Hosted Zone trong Route53
  name    = "grafana.gitlabonlinecom.click"  # 👈 Thay domain của bạn
  type    = "A"

  alias {
    name                   = "dualstack.${aws_lb.main_alb.dns_name}"  # DNS name của ALB
    zone_id                = aws_lb.main_alb.zone_id   # Zone ID của ALB
    evaluate_target_health = true  # Kiểm tra health check của ALB
  }
  depends_on = [ aws_lb.main_alb ]
}

resource "aws_route53_record" "alb_prometheus_alias" {
  zone_id = var.route53_zone_id  # ID của Hosted Zone trong Route53
  name    = "prometheus.gitlabonlinecom.click"  # 👈 Thay domain của bạn
  type    = "A"

  alias {
    name                   = "dualstack.${aws_lb.main_alb.dns_name}"  # DNS name của ALB
    zone_id                = aws_lb.main_alb.zone_id   # Zone ID của ALB
    evaluate_target_health = true  # Kiểm tra health check của ALB
  }
  depends_on = [ aws_lb.main_alb ]
}
*/