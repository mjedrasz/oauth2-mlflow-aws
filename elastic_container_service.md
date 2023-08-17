# Elastic Container Service

We deploy MLFlow and oauth2-proxy services as containers using [Elastic Container Service](https://docs.aws.amazon.com/ecs/index.html), ECS ([AWS App Runner](https://aws.amazon.com/apprunner/) is a nice serverless alternative, but at the time of creating this repository AWS App Runner service was available only in limited locations). We have two containers defined in an ECS task. Given that multiple containers within an ECS task in `awsvpc` networking mode share the network namespace, they can communicate with each other using localhost (similar to containers in the same kubernetes pod).

A relevant Terraform container definition for the MLFlow service is shown below.

```json
{
  name      = "mlflow"
  image     = "gcr.io/getindata-images-public/mlflow:1.22.0"
  entryPoint = ["sh", "-c"]
  command = [
    <<EOT
      /bin/sh -c "mlflow server \
        --host=0.0.0.0 \
        --port=${local.mlflow_port} \
        --default-artifact-root=s3://${aws_s3_bucket.artifacts.bucket}${var.artifact_bucket_path} \
        --backend-store-uri=mysql+pymysql://${aws_rds_cluster.backend_store.master_username}:`echo -n $DB_PASSWORD`@${aws_rds_cluster.backend_store.endpoint}:${aws_rds_cluster.backend_store.port}/${aws_rds_cluster.backend_store.database_name} \
        --gunicorn-opts '${var.gunicorn_opts}'"
    EOT
  ]
  portMappings = [{ containerPort = local.mlflow_port }]
  secrets = [
    {
      name      = "DB_PASSWORD"
      valueFrom = data.aws_secretsmanager_secret.db_password.arn
    }
  ]
}
```

The container setup is simple - we just start the MLFlow server with some options. Sensitive data, i.e., database password is fetched from Secret Manager (a cheaper option, but less robust, would be to use Systems Manager Parameter Store). ECS task is also given a role to access S3 where MLFlow stores  artefacts.

```json
resource "aws_iam_role_policy" "s3" {
  name = "${var.unique_name}-s3"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${aws_s3_bucket.artifacts.bucket}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:*Object"]
        Resource = ["arn:aws:s3:::${aws_s3_bucket.artifacts.bucket}/*"]
      },
    ]
  })
}
```

However, passing the backend store uri is at the moment a little bit convoluted. AWS ECS doesn't allow interpolating secrets in CLI arguments at runtime hence we need a shell. Preferably, MLFlow server should introduce an option to specify this value via an environment variable (there is an issue for that https://github.com/mlflow/mlflow/issues/3122).

Similarly, `oauth2-proxy` container definition is as follows.

```json
{
  name      = "oauth2-proxy"
  image     = "bitnami/oauth2-proxy:7.2.1"
  command   = [
    "--http-address", "0.0.0.0:8080",
    "--upstream", "http://localhost:${local.mlflow_port}",
    "--email-domain", "*",
    "--provider", "google",
    "--skip-jwt-bearer-tokens", "true",
    "--extra-jwt-issuers", "https://accounts.google.com=32555940559.apps.googleusercontent.com"
  ]
  portMappings = [{ containerPort = local.oauth2_proxy_port }]
  secrets = [
    {
      name      = "OAUTH2_PROXY_CLIENT_ID"
      valueFrom = data.aws_secretsmanager_secret.oauth2_client_id.arn
    },
    {
      name      = "OAUTH2_PROXY_CLIENT_SECRET"
      valueFrom = data.aws_secretsmanager_secret.oauth2_client_secret.arn
    },
    {
      name      = "OAUTH2_PROXY_COOKIE_SECRET"
      valueFrom = data.aws_secretsmanager_secret.oauth2_cookie_secret.arn
    },
  ]
}
```

Note, that `--extra-jwt-issuers` configuration option is needed to support programmatic access.

The premise of our setup is to put `oauth2-proxy` in front of MLFlow server, thus adding authorization capabilities. For this reason we configure ECS service's load balancer to point to the `oauth2-proxy` container, which, as the name implies, acts as a proxy to the MLFlow server.

```json
resource "aws_ecs_service" "mlflow" {

  # other attributes

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "oauth2-proxy"
    container_port   = local.oauth2_proxy_port
  }
}
```