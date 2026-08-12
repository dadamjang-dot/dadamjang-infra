resource "aws_security_group" "alb" {
  description = "Public ingress for the e2e API load balancer."
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
    description = "HTTP redirect"
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
}

resource "aws_security_group" "api" {
  description = "API task ingress only from the e2e ALB."
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
}

resource "aws_security_group" "database" {
  description = "PostgreSQL ingress only from e2e API tasks."
  name        = "${local.name_prefix}-database"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API to PostgreSQL"
    from_port       = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    to_port         = 5432
  }
}

resource "aws_security_group" "redis" {
  description = "Redis ingress only from e2e API tasks."
  name        = "${local.name_prefix}-redis"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API to Redis"
    from_port       = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    to_port         = 6379
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
      action       = { type = "expire" }
      description  = "Keep the 10 newest e2e API images."
      rulePriority = 1
      selection = {
        countNumber = 10
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
  description             = "JSON runtime secrets for the isolated DADAMJANG e2e API."
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
  backup_retention_period     = 0
  db_name                     = local.database_name
  db_subnet_group_name        = aws_db_subnet_group.main.name
  deletion_protection         = false
  engine                      = "postgres"
  engine_version              = "16"
  identifier                  = "${local.name_prefix}-postgres"
  instance_class              = var.database_instance_class
  manage_master_user_password = true
  multi_az                    = false
  publicly_accessible         = false
  skip_final_snapshot         = true
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
  description                = "DADAMJANG e2e Redis"
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
    matcher             = "200-499"
    path                = "/graphql"
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
    target_group_arn = aws_lb_target_group.api.arn
    type             = "forward"
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
  container_definitions = jsonencode([{
    command = ["node", "dist/main.js"]
    environment = [
      { name = "NODE_ENV", value = "e2e" },
      { name = "POSTGRES_DATABASE", value = local.database_name },
      { name = "POSTGRES_HOST", value = aws_db_instance.main.address },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "POSTGRES_USERNAME", value = var.database_username },
      { name = "REDIS_URL", value = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379" },
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
    secrets = concat([{
      name      = "POSTGRES_PASSWORD"
      valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
      }], [for key in local.runtime_secret_keys : {
      name      = key
      valueFrom = "${aws_secretsmanager_secret.api_runtime.arn}:${key}::"
    }])
  }])
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
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.https]
}
