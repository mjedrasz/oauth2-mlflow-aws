resource "aws_route53_record" "mlflow_record" {
  zone_id = data.aws_route53_zone.hosted_zone.zone_id
  name    = "${var.dns_record_name}.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.mlflow.dns_name
    zone_id                = aws_lb.mlflow.zone_id
    evaluate_target_health = true
  }
}

data "aws_route53_zone" "hosted_zone" {
  name = var.hosted_zone
}