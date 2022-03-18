variable "unique_name" {
  type        = string
  description = "A unique name for this application"
  default     = "oauth2-mlflow"
}

variable "hosted_zone" {
  type        = string
  description = "Route 53 hosted zone"
}

variable "dns_record_name" {
  type        = string
  description = "MLFlow DNS record name"
}

variable "domain" {
  type        = string
  description = "MLFlow DNS domain"
}

variable "load_balancer_is_internal" {
  type    = bool
  default = false
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "AWS Tags common to all the resources created"
}

variable "service_cpu" {
  type        = number
  default     = 2048
  description = "The number of CPU units reserved for the MLflow container"
}

variable "service_memory" {
  type        = number
  default     = 4096
  description = "The amount (in MiB) of memory reserved for the MLflow container"
}

variable "service_log_retention_in_days" {
  type        = number
  default     = 30
  description = "The number of days to keep logs around"
}

variable "service_min_capacity" {
  type        = number
  default     = 1
  description = "Minimum number of instances for the ecs service. This will create an aws_appautoscaling_target that can later on be used to autoscale the MLflow instance"
}

variable "service_max_capacity" {
  type        = number
  default     = 4
  description = "Maximum number of instances for the ecs service. This will create an aws_appautoscaling_target that can later on be used to autoscale the MLflow instance"
}

variable "database_max_capacity" {
  type        = number
  default     = 4
  description = "The maximum capacity for the Aurora Serverless cluster. Aurora will scale automatically in this range. See: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless.how-it-works.html"
}

variable "database_auto_pause" {
  type        = bool
  default     = true
  description = "Pause Aurora Serverless after a given amount of time with no activity. https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless.how-it-works.html#aurora-serverless.how-it-works.pause-resume"
}

variable "database_seconds_until_auto_pause" {
  type        = number
  default     = 300
  description = "The number of seconds without activity before Aurora Serverless is paused. https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless.how-it-works.html#aurora-serverless.how-it-works.pause-resume"
}

variable "database_skip_final_snapshot" {
  type    = bool
  default = true
}

variable "artifact_bucket_path" {
  type        = string
  default     = "/"
  description = "The path within the bucket where MLflow will store its artifacts"
}

variable "gunicorn_opts" {
  description = "Additional command line options forwarded to gunicorn processes (https://mlflow.org/docs/latest/cli.html#cmdoption-mlflow-server-gunicorn-opts)"
  type        = string
  default     = ""
}
