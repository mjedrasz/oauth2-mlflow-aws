output "mlflow_uri" {
  value = "https://${var.dns_record_name}.${var.domain}"
}
