locals {
  mlflow_port       = 4180
  oauth2_proxy_port = 8080
  db_port           = 3306
  tags = merge(
    {
      "env"     = "dev"
      "project" = "oauth2-mlflow"
    },
    var.tags
  )
}


