

resource "aws_db_subnet_group" "rds" {
  name       = "${var.unique_name}-rds"
  subnet_ids = module.vpc.database_subnets
}

resource "aws_security_group" "rds" {
  name   = "${var.unique_name}-rds"
  vpc_id = module.vpc.vpc_id
  tags   = local.tags

  ingress {
    from_port       = local.db_port
    to_port         = local.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_rds_cluster" "backend_store" {
  cluster_identifier        = var.unique_name
  apply_immediately         = true
  tags                      = local.tags
  engine                    = "aurora-mysql"
  engine_version            = "5.7.mysql_aurora.2.08.3"
  engine_mode               = "serverless"
  port                      = local.db_port
  db_subnet_group_name      = aws_db_subnet_group.rds.name
  vpc_security_group_ids    = [aws_security_group.rds.id]
  master_username           = "ecs_task"
  database_name             = "mlflow"
  skip_final_snapshot       = var.database_skip_final_snapshot
  final_snapshot_identifier = var.unique_name
  master_password           = data.aws_secretsmanager_secret_version.db_password.secret_string
  backup_retention_period   = 14

  scaling_configuration {
    max_capacity             = var.database_max_capacity
    auto_pause               = var.database_auto_pause
    seconds_until_auto_pause = var.database_seconds_until_auto_pause
    timeout_action           = "ForceApplyCapacityChange"
  }
}
