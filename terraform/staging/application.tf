resource "aws_security_group" "alb" {
  description = "Public ingress for the staging API load balancer."
  name        = "${local.name_prefix}-alb"
  vpc_id      = aws_vpc.main.id

  ingress {
    cidr_blocks = tolist(var.alb_ingress_cidrs)
    description = "HTTPS traffic"
    from_port   = 443
    protocol    = "tcp"
    to_port     = 443
  }

  ingress {
    cidr_blocks = tolist(var.alb_ingress_cidrs)
    description = "HTTP traffic"
    from_port   = 80
    protocol    = "tcp"
    to_port     = 80
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound traffic"
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_security_group" "api" {
  description = "API task ingress only from the staging ALB."
  name        = "${local.name_prefix}-api"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ALB to API"
    from_port       = 5500
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    to_port         = 5500
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound traffic"
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

resource "aws_security_group" "database" {
  description = "PostgreSQL ingress only from API tasks."
  name        = "${local.name_prefix}-database"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API to PostgreSQL"
    from_port       = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    to_port         = 5432
  }

  tags = {
    Name = "${local.name_prefix}-database"
  }
}

resource "aws_security_group" "redis" {
  description = "Redis ingress only from API tasks."
  name        = "${local.name_prefix}-redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API to Redis"
    from_port       = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    to_port         = 6379
  }

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}

resource "aws_ecr_repository" "api" {
  force_delete         = false
  image_tag_mutability = "IMMUTABLE"
  name                 = "${local.name_prefix}-api"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      action = {
        type = "expire"
      }
      description  = "Keep the 20 newest API images."
      rulePriority = 1
      selection = {
        countNumber = 20
        countType   = "imageCountMoreThan"
        tagStatus   = "any"
      }
    }]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name_prefix}-api"
  retention_in_days = var.log_retention_in_days
}

resource "aws_secretsmanager_secret" "api_runtime" {
  description             = "JSON runtime secrets for the DADAMJANG staging API."
  name                    = "${local.name_prefix}/api-runtime"
  recovery_window_in_days = 7
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-database"
  subnet_ids = values(aws_subnet.private)[*].id
}

resource "aws_db_instance" "main" {
  allocated_storage           = 20
  apply_immediately           = false
  backup_retention_period     = 7
  copy_tags_to_snapshot       = true
  db_name                     = var.database_name
  db_subnet_group_name        = aws_db_subnet_group.main.name
  deletion_protection         = var.enable_deletion_protection
  engine                      = "postgres"
  engine_version              = "16"
  final_snapshot_identifier   = var.skip_final_snapshot ? null : coalesce(var.final_snapshot_identifier, "${local.name_prefix}-postgres-final")
  identifier                  = "${local.name_prefix}-postgres"
  instance_class              = var.database_instance_class
  manage_master_user_password = true
  multi_az                    = false
  publicly_accessible         = false
  skip_final_snapshot         = var.skip_final_snapshot
  storage_encrypted           = true
  storage_type                = "gp3"
  username                    = var.database_username
  vpc_security_group_ids      = [aws_security_group.database.id]

}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = values(aws_subnet.private)[*].id
}

resource "aws_elasticache_replication_group" "main" {
  apply_immediately          = false
  at_rest_encryption_enabled = true
  automatic_failover_enabled = false
  description                = "DADAMJANG staging Redis"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  replication_group_id       = "${local.name_prefix}-redis"
  security_group_ids         = [aws_security_group.redis.id]
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  transit_encryption_enabled = true
}

resource "aws_lb" "api" {
  internal           = false
  load_balancer_type = "application"
  name               = "${local.name_prefix}-api"
  security_groups    = [aws_security_group.alb.id]
  subnets            = values(aws_subnet.public)[*].id
}

resource "aws_lb_target_group" "api" {
  health_check {
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health/ready"
    timeout             = 5
    unhealthy_threshold = 3
  }

  name        = "${local.name_prefix}-api"
  port        = 5500
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
}

resource "aws_lb_listener" "http" {
  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
}

resource "aws_lb_listener" "https" {
  certificate_arn   = var.acm_certificate_arn
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.api.arn
        weight = 1
      }
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "api" {
  container_definitions = jsonencode([
    {
      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "POSTGRES_DATABASE", value = var.database_name },
        { name = "POSTGRES_HOST", value = aws_db_instance.main.address },
        { name = "POSTGRES_PORT", value = "5432" },
        { name = "POSTGRES_SSL", value = "true" },
        { name = "POSTGRES_SSL_CA_PATH", value = "/etc/ssl/certs/aws-rds-global-bundle.pem" },
        { name = "POSTGRES_USERNAME", value = var.database_username },
        { name = "REDIS_URL", value = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379" },
        { name = "SENTRY_ENVIRONMENT", value = "staging" },
        { name = "SENTRY_RELEASE", value = var.api_image_tag },
        { name = "TRUST_PROXY", value = "true" },
      ]
      essential = true
      image     = "${aws_ecr_repository.api.repository_url}:${var.api_image_tag}"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
        }
      }
      name = "api"
      portMappings = [{
        containerPort = 5500
        hostPort      = 5500
        protocol      = "tcp"
      }]
      secrets = concat([
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
        }
        ], [for key in local.runtime_secret_keys : {
          name      = key
          valueFrom = "${aws_secretsmanager_secret.api_runtime.arn}:${key}::"
      }])
    }
  ])
  cpu                      = tostring(var.api_container_cpu)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  family                   = "${local.name_prefix}-api"
  memory                   = tostring(var.api_container_memory)
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.ecs_task.arn
}

resource "aws_ecs_service" "api" {
  cluster          = aws_ecs_cluster.main.id
  desired_count    = 0
  launch_type      = "FARGATE"
  name             = "${local.name_prefix}-api"
  platform_version = "LATEST"
  task_definition  = aws_ecs_task_definition.api.arn

  load_balancer {
    container_name   = "api"
    container_port   = 5500
    target_group_arn = aws_lb_target_group.api.arn
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.api.id]
    subnets          = values(aws_subnet.private)[*].id
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [
      desired_count,
      task_definition,
    ]
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_cloudwatch_metric_alarm" "api_cpu" {
  alarm_actions       = var.alarm_action_arns
  alarm_name          = "${local.name_prefix}-api-high-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api.name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_memory" {
  alarm_actions       = var.alarm_action_arns
  alarm_name          = "${local.name_prefix}-api-high-memory"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.api.name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_alb_5xx" {
  alarm_actions       = var.alarm_action_arns
  alarm_name          = "${local.name_prefix}-api-alb-5xx"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.api.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "api_unhealthy_hosts" {
  alarm_actions       = var.alarm_action_arns
  alarm_name          = "${local.name_prefix}-api-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.api.arn_suffix
    TargetGroup  = aws_lb_target_group.api.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "api_zero_healthy_hosts" {
  alarm_actions       = var.alarm_action_arns
  alarm_name          = "${local.name_prefix}-api-zero-healthy-hosts"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.api.arn_suffix
    TargetGroup  = aws_lb_target_group.api.arn_suffix
  }
}
