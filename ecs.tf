data "aws_region" "current" {}

data "aws_secretsmanager_secret" "oauth2_client_id" {
  name = "mlflow/oauth2-client-id"
}

data "aws_secretsmanager_secret_version" "oauth2_client_id" {
  secret_id = data.aws_secretsmanager_secret.oauth2_client_id.id
}

data "aws_secretsmanager_secret" "oauth2_client_secret" {
  name = "mlflow/oauth2-client-secret"
}

data "aws_secretsmanager_secret_version" "oauth2_client_secret" {
  secret_id = data.aws_secretsmanager_secret.oauth2_client_secret.id
}

data "aws_secretsmanager_secret" "oauth2_cookie_secret" {
  name = "mlflow/oauth2-cookie-secret"
}

data "aws_secretsmanager_secret_version" "oauth2_cookie_secret" {
  secret_id = data.aws_secretsmanager_secret.oauth2_cookie_secret.id
}

data "aws_secretsmanager_secret" "db_password" {
  name = "mlflow/store-db-password"
}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = data.aws_secretsmanager_secret.db_password.id
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.unique_name}-ecs-task"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect = "Allow"
      },
    ]
  })

}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.unique_name}-ecs-execution"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Effect = "Allow"
      },
    ]
  })

}

resource "aws_iam_role_policy" "secrets" {
  name = "${var.unique_name}-read-secret"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = [
          data.aws_secretsmanager_secret_version.db_password.arn,
          data.aws_secretsmanager_secret.oauth2_client_id.arn,
          data.aws_secretsmanager_secret.oauth2_client_secret.arn,
          data.aws_secretsmanager_secret.oauth2_cookie_secret.arn
        ]
      },
    ]
  })
}

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

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_execution.name
}

resource "aws_security_group" "ecs_service" {
  name = "${var.unique_name}-ecs-service"
  tags = local.tags

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = local.oauth2_proxy_port
    to_port         = local.oauth2_proxy_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/aws/ecs/mlflow/${var.unique_name}"
  retention_in_days = var.service_log_retention_in_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "oauth2_proxy" {
  name              = "/aws/ecs/oauth2-proxy/${var.unique_name}"
  retention_in_days = var.service_log_retention_in_days
  tags              = local.tags
}

resource "aws_ecs_cluster" "mlflow" {
  name = var.unique_name
  tags = local.tags
}

resource "aws_ecs_task_definition" "mlflow" {
  family = var.unique_name
  tags   = local.tags
  container_definitions = jsonencode(concat([
    {
      name      = "mlflow"
      image     = "gcr.io/getindata-images-public/mlflow:1.22.0"
      essential = true

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
      environment = [
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.name
        },
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = data.aws_secretsmanager_secret.db_password.arn
        }
      ]
      logConfiguration = {
        logDriver     = "awslogs"
        secretOptions = null
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mlflow.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name  = "oauth2-proxy"
      image = "bitnami/oauth2-proxy:7.2.1"
      command = [
        "--http-address", "0.0.0.0:8080",
        "--upstream", "http://localhost:${local.mlflow_port}",
        "--cookie-secure", "false",
        "--cookie-refresh", "5m",
        "--email-domain", "*",
        "--provider", "google",
        "--skip-jwt-bearer-tokens", "true",
        "--extra-jwt-issuers", "https://accounts.google.com=32555940559.apps.googleusercontent.com"
      ]
      essential = true

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
      logConfiguration = {
        logDriver     = "awslogs"
        secretOptions = null
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.oauth2_proxy.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
  ]))

  network_mode             = "awsvpc"
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.service_cpu
  memory                   = var.service_memory
}

resource "aws_ecs_service" "mlflow" {
  name             = var.unique_name
  cluster          = aws_ecs_cluster.mlflow.id
  task_definition  = aws_ecs_task_definition.mlflow.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "1.4.0"


  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "oauth2-proxy"
    container_port   = local.oauth2_proxy_port
  }

  depends_on = [
    aws_lb.mlflow,
  ]
}

resource "aws_appautoscaling_target" "mlflow" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.mlflow.name}/${aws_ecs_service.mlflow.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  max_capacity       = var.service_max_capacity
  min_capacity       = var.service_min_capacity
}

resource "aws_security_group" "lb" {
  name   = "${var.unique_name}-lb"
  tags   = local.tags
  vpc_id = module.vpc.vpc_id
}

resource "aws_security_group_rule" "lb_ingress_https" {
  description       = "Only allow load balancer to reach the ECS service on the right port"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lb.id
}

resource "aws_security_group_rule" "lb_egress" {
  description              = "Only allow load balancer to reach the ECS service on the right port"
  type                     = "egress"
  from_port                = local.oauth2_proxy_port
  to_port                  = local.oauth2_proxy_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_service.id
  security_group_id        = aws_security_group.lb.id
}

resource "aws_lb" "mlflow" {
  name               = var.unique_name
  tags               = local.tags
  internal           = var.load_balancer_is_internal ? true : false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "mlflow" {
  name        = var.unique_name
  port        = local.oauth2_proxy_port
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    protocol = "HTTP"
    matcher  = "200-202"
    path     = "/ping"
  }
}

data "aws_acm_certificate" "certificate" {
  domain = var.domain
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.mlflow.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = data.aws_acm_certificate.certificate.arn

  default_action {
    target_group_arn = aws_lb_target_group.mlflow.arn
    type             = "forward"
  }
  tags = local.tags
}
