data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

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
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.ecs_execution.name
}

data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
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

data "aws_iam_policy_document" "mobile_e2e_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.mobile_github_repository}:environment:${var.mobile_github_environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository"
      values   = [var.mobile_github_repository]
    }

    principals {
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "mobile_e2e" {
  assume_role_policy = data.aws_iam_policy_document.mobile_e2e_assume_role.json
  name               = "${local.name_prefix}-mobile-ci"
}

data "aws_iam_policy_document" "mobile_e2e" {
  statement {
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [aws_ecs_service.api.id]
  }

  statement {
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    actions   = ["ecs:RunTask"]
    resources = ["arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.api.family}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  statement {
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.main.name}/*"]
  }

  statement {
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.ecs_execution.arn,
      aws_iam_role.ecs_task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "mobile_e2e" {
  name   = "${local.name_prefix}-lifecycle"
  policy = data.aws_iam_policy_document.mobile_e2e.json
  role   = aws_iam_role.mobile_e2e.id
}
