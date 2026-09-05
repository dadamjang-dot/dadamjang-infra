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

mock_provider "cloudflare" {}

run "release_contracts" {
  command = apply

  override_resource {
    target = aws_iam_role.ecs_execution
    values = {
      arn = "arn:aws:iam::123456789012:role/dadamjang-e2e-ecs-execution"
    }
  }

  override_resource {
    target = aws_iam_role.ecs_task
    values = {
      arn = "arn:aws:iam::123456789012:role/dadamjang-e2e-ecs-task"
    }
  }

  variables {
    acm_certificate_arn             = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    api_hostname                    = "api.e2e.example.test"
    cloudflare_account_id           = "00000000000000000000000000000000"
    cloudflare_r2_final_bucket_name = "dadamjang-e2e-final"
  }

  assert {
    condition = alltrue([
      cloudflare_r2_bucket.pending.account_id == var.cloudflare_account_id,
      cloudflare_r2_bucket.pending.name == "dadamjang-e2e-pending",
      cloudflare_r2_bucket.pending.name != var.cloudflare_r2_final_bucket_name,
      cloudflare_r2_bucket.pending.location == "apac",
      cloudflare_r2_bucket.pending.storage_class == "Standard",
      cloudflare_r2_bucket_lifecycle.pending.bucket_name == cloudflare_r2_bucket.pending.name,
      cloudflare_r2_bucket_lifecycle.pending.rules[0].enabled,
      cloudflare_r2_bucket_lifecycle.pending.rules[0].conditions.prefix == "",
      cloudflare_r2_bucket_lifecycle.pending.rules[0].delete_objects_transition.condition.type == "Age",
      cloudflare_r2_bucket_lifecycle.pending.rules[0].delete_objects_transition.condition.max_age == 86400,
      cloudflare_r2_managed_domain.pending.bucket_name == cloudflare_r2_bucket.pending.name,
      !cloudflare_r2_managed_domain.pending.enabled,
      output.pending_r2_bucket_name == cloudflare_r2_bucket.pending.name,
      output.r2_application_bucket_names == sort([
        var.cloudflare_r2_final_bucket_name,
        cloudflare_r2_bucket.pending.name,
      ]),
    ])
    error_message = "The e2e pending R2 bucket must be distinct, private, and expire objects after one day."
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.api.container_definitions)[0]), "command")
    error_message = "The e2e task must use the image entrypoint for migrations."
  }

  assert {
    condition     = output.e2e_api_url == "https://api.e2e.example.test/graphql"
    error_message = "The mobile API URL must target the backend GraphQL route."
  }

  assert {
    condition     = output.e2e_aws_region == var.aws_region
    error_message = "The mobile workflow region must match the Terraform provider region."
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
    condition = try(
      toset(keys(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy))) == toset(["Statement", "Version"]) &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Version == "2012-10-17" &&
      length(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement) == 1 &&
      toset(keys(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0])) == toset(["Action", "Condition", "Effect", "Principal"]) &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Effect == "Allow" &&
      toset(keys(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Principal)) == toset(["Federated"]) &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Principal.Federated == data.aws_iam_openid_connect_provider.github_actions.arn &&
      toset(keys(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Condition)) == toset(["StringEquals"]) &&
      toset(keys(jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Condition.StringEquals)) == toset([
        "token.actions.githubusercontent.com:aud",
        "token.actions.githubusercontent.com:repository",
        "token.actions.githubusercontent.com:sub",
      ]) &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository"] == var.mobile_github_repository &&
      jsondecode(aws_iam_role.mobile_e2e.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:${var.mobile_github_repository}:environment:${var.mobile_github_environment}",
      false,
    )
    error_message = "Mobile E2E OIDC trust must contain only the exact audience, repository, and environment subject."
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement : statement
      if try(contains(tolist(statement.Action), "ecs:DescribeTaskDefinition"), statement.Action == "ecs:DescribeTaskDefinition")
    ]) == 0
    error_message = "Mobile E2E IAM must not grant the unused ecs:DescribeTaskDefinition action."
  }

  assert {
    condition = try(
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy))) == toset(["Statement", "Version"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Version == "2012-10-17" &&
      length(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement) == 4 &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[0])) == toset(["Action", "Effect", "Resource"]) &&
      toset(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[0].Action) == toset(["ecs:DescribeServices", "ecs:UpdateService"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[0].Resource == aws_ecs_service.api.id &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1])) == toset(["Action", "Condition", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Action == "ecs:RunTask" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Resource == "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.api.family}:*" &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Condition)) == toset(["ArnEquals"]) &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Condition.ArnEquals)) == toset(["ecs:cluster"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[1].Condition.ArnEquals["ecs:cluster"] == aws_ecs_cluster.main.arn &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[2])) == toset(["Action", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[2].Action == "ecs:DescribeTasks" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[2].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[2].Resource == "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.main.name}/*" &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3])) == toset(["Action", "Condition", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Action == "iam:PassRole" &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Effect == "Allow" &&
      length(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Resource) == 2 &&
      toset(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Resource) == toset([aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn]) &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Condition)) == toset(["StringEquals"]) &&
      toset(keys(jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Condition.StringEquals)) == toset(["iam:PassedToService"]) &&
      jsondecode(aws_iam_role_policy.mobile_e2e.policy).Statement[3].Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com",
      false,
    )
    error_message = "Mobile E2E IAM must contain exactly the reviewed ECS lifecycle and PassRole permissions."
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
      "CLOUDFLARE_R2_BUCKET", "CLOUDFLARE_R2_ENDPOINT", "CLOUDFLARE_R2_PENDING_BUCKET", "CLOUDFLARE_R2_PUBLIC_BASE_URL", "CLOUDFLARE_R2_SECRET_ACCESS_KEY",
      "DADAMJANG_BFF_SECRET", "DADAMJANG_BO_URL", "EMAIL_CODE_PEPPER", "IDENTITY_CI_PEPPER", "IDENTITY_INICIS_API_KEY",
      "IDENTITY_INICIS_CALLBACK_BASE_URL", "IDENTITY_INICIS_MID", "IDENTITY_INICIS_SEED_IV", "JWT_ACCESS_TOKEN_EXP",
      "JWT_ACCESS_TOKEN_SECRET", "JWT_REFRESH_TOKEN_EXP", "JWT_REFRESH_TOKEN_SECRET", "KAKAO_CALLBACK_URL",
      "KAKAO_CLIENT_ID", "RESEND_API_KEY", "RESEND_FROM_EMAIL", "SENTRY_DSN",
    ])
    error_message = "The e2e runtime secret contract must match staging."
  }

  assert {
    condition = sort([
      for secret in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : secret.name
    ]) == sort(concat(["POSTGRES_PASSWORD"], tolist(local.runtime_secret_keys)))
    error_message = "The e2e task secret set must exactly match the reviewed runtime contract."
  }

  assert {
    condition = one([
      for secret in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : secret.valueFrom
      if secret.name == "DADAMJANG_BFF_SECRET"
    ]) == "${aws_secretsmanager_secret.api_runtime.arn}:DADAMJANG_BFF_SECRET::"
    error_message = "The API task must inject the BFF authentication secret from its runtime JSON secret."
  }
}

run "reject_shared_final_and_pending_bucket" {
  command = plan

  variables {
    acm_certificate_arn             = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    api_hostname                    = "api.e2e.example.test"
    cloudflare_account_id           = "00000000000000000000000000000000"
    cloudflare_r2_final_bucket_name = "dadamjang-e2e-pending"
  }

  expect_failures = [cloudflare_r2_bucket.pending]
}
