# Hosted zone public cho var.domain và name server của domain.
resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "DevOps tools (Terraform)"
}

# Domain đã đăng ký bằng Route 53 trong account này: trỏ NS về hosted zone ở trên.
# Resource này KHÔNG mua domain mới; destroy chỉ gỡ khỏi state, không xoá domain.
resource "aws_route53domains_registered_domain" "main" {
  count    = var.manage_domain_nameservers ? 1 : 0
  provider = aws.us_east_1 # Route 53 Domains chỉ có ở us-east-1

  domain_name = var.domain
  auto_renew  = true

  dynamic "name_server" {
    for_each = aws_route53_zone.main.name_servers
    content {
      name = name_server.value
    }
  }
}

output "name_servers" {
  description = "Name server của hosted zone (trỏ domain về đây nếu đăng ký ở nơi khác)"
  value       = aws_route53_zone.main.name_servers
}
