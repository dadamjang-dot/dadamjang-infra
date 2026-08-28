data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  name               = "${local.name_prefix}-ecs-execution"
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_execution.name
}

data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_db_instance.main.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.api_runtime.arn,
    ]
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "${local.name_prefix}-read-secrets"
  policy = data.aws_iam_policy_document.ecs_execution_secrets.json
  role   = aws_iam_role.ecs_execution.id
}

resource "aws_iam_role" "ecs_task" {
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  name               = "${local.name_prefix}-ecs-task"
}

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_api_deploy_assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.environment}"
        }
      }
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github_actions.arn
      }
    }]
    Version = "2012-10-17"
  })

  github_api_deploy_policy = jsonencode({
    Statement = [
      {
        Action   = "ecr:GetAuthorizationToken"
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Effect   = "Allow"
        Resource = aws_ecr_repository.api.arn
      },
      {
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Effect   = "Allow"
        Resource = aws_ecs_service.api.id
      },
      {
        Action    = "ecs:RunTask"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.main.arn } }
        Effect    = "Allow"
        Resource  = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.api.family}:*"
      },
      {
        Action   = "ecs:DescribeTasks"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.main.name}/*"
      },
      {
        Action = "iam:PassRole"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
        Effect = "Allow"
        Resource = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn,
        ]
      },
    ]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role" "github_api_deploy" {
  assume_role_policy = local.github_api_deploy_assume_role_policy
  name               = "${local.name_prefix}-github-api-deploy"
}

resource "aws_iam_role_policy" "github_api_deploy" {
  name   = "${local.name_prefix}-github-api-deploy"
  policy = local.github_api_deploy_policy
  role   = aws_iam_role.github_api_deploy.id
}
