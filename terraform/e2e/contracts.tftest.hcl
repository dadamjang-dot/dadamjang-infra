mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-northeast-2a", "ap-northeast-2b"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/dadamjang-e2e"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address            = "database.example.test"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:database" }]
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/dadamjang-e2e-api"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dadamjang-e2e-api/0000000000000000"
      arn_suffix = "app/dadamjang-e2e-api/0000000000000000"
      dns_name   = "e2e-api.example.test"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/dadamjang-e2e-api/0000000000000000"
      arn_suffix = "targetgroup/dadamjang-e2e-api/0000000000000000"
    }
  }
}

run "release_contracts" {
  command = apply

  variables {
    acm_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    api_hostname        = "api.e2e.example.test"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.api.container_definitions)[0]), "command")
    error_message = "The e2e task must use the image entrypoint for migrations."
  }

  assert {
    condition = (
      length(jsondecode(aws_ecr_lifecycle_policy.api.policy).rules) > 0 &&
      alltrue([
        for rule in jsondecode(aws_ecr_lifecycle_policy.api.policy).rules :
        try(rule.action.type, null) == "expire" &&
        try(rule.selection.tagStatus, null) == "untagged" &&
        try(rule.selection.countType, null) == "sinceImagePushed" &&
        try(rule.selection.countUnit, null) == "days" &&
        try(rule.selection.countNumber, 0) > 0
      ])
    )
    error_message = "E2E must expire only untagged images by age."
  }

  assert {
    condition = alltrue([
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "POSTGRES_SSL"]) == "true",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "POSTGRES_SSL_CA_PATH"]) == "/etc/ssl/certs/aws-rds-global-bundle.pem",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "SENTRY_ENVIRONMENT"]) == "e2e",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "SENTRY_RELEASE"]) == var.api_image_tag,
      aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "X86_64",
      aws_ecs_task_definition.api.runtime_platform[0].operating_system_family == "LINUX",
      aws_lb_target_group.api.health_check[0].path == "/health/ready",
      aws_lb_target_group.api.health_check[0].matcher == "200",
      !aws_db_instance.main.deletion_protection,
      aws_db_instance.main.skip_final_snapshot,
      aws_ecs_service.api.task_definition == aws_ecs_task_definition.api.arn,
    ])
    error_message = "The e2e release contract must preserve task runtime, readiness, and disposable RDS settings."
  }

  assert {
    condition = sort(tolist(local.runtime_secret_keys)) == sort([
      "API_PUBLIC_BASE_URL", "CLIENT_URL", "CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL", "CLOUDFLARE_R2_ACCESS_KEY_ID",
      "CLOUDFLARE_R2_BUCKET", "CLOUDFLARE_R2_ENDPOINT", "CLOUDFLARE_R2_PUBLIC_BASE_URL", "CLOUDFLARE_R2_SECRET_ACCESS_KEY",
      "DADAMJANG_BO_URL", "EMAIL_CODE_PEPPER", "IDENTITY_CI_PEPPER", "IDENTITY_INICIS_API_KEY",
      "IDENTITY_INICIS_CALLBACK_BASE_URL", "IDENTITY_INICIS_MID", "IDENTITY_INICIS_SEED_IV", "JWT_ACCESS_TOKEN_EXP",
      "JWT_ACCESS_TOKEN_SECRET", "JWT_REFRESH_TOKEN_EXP", "JWT_REFRESH_TOKEN_SECRET", "KAKAO_CALLBACK_URL",
      "KAKAO_CLIENT_ID", "RESEND_API_KEY", "RESEND_FROM_EMAIL", "SENTRY_DSN",
    ])
    error_message = "The e2e runtime secret contract must match staging."
  }
}
