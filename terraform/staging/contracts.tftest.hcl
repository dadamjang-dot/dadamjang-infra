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

  mock_resource "aws_db_instance" {
    defaults = {
      address            = "database.example.test"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:database" }]
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/dadamjang-staging-api"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/dadamjang-staging"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dadamjang-staging-api/0000000000000000"
      arn_suffix = "app/dadamjang-staging-api/0000000000000000"
      dns_name   = "staging-api.example.test"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/dadamjang-staging-api/0000000000000000"
      arn_suffix = "targetgroup/dadamjang-staging-api/0000000000000000"
    }
  }
}

run "release_contracts" {
  command = apply

  variables {
    acm_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    api_hostname        = "api.staging.example.test"
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.comparison_operator == "LessThanThreshold" &&
      aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.threshold == 1
    )
    error_message = "The zero-healthy-host alarm must breach below one healthy target."
  }

  assert {
    condition = (
      aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "X86_64" &&
      aws_ecs_task_definition.api.runtime_platform[0].operating_system_family == "LINUX"
    )
    error_message = "The staging task must run the published linux/amd64 image."
  }

  assert {
    condition = output.ecs_release_contract.runtime_secret_names == sort(concat(
      ["POSTGRES_PASSWORD"],
      tolist(local.runtime_secret_keys),
    ))
    error_message = "The ECS release transition must export the exact runtime secret contract."
  }

  assert {
    condition = (
      toset(keys(output.ecs_release_contract)) == toset([
        "canonical_task_definition_arn",
        "image_repository",
        "observed_service_task_definition_arn",
        "runtime_secret_names",
        "source_hashes",
        "task_family",
      ]) &&
      toset(keys(output.ecs_release_contract.source_hashes)) == setunion(
        fileset(path.module, "*.tf"),
        toset([".terraform.lock.hcl"]),
      )
    )
    error_message = "The ECS release transition must retain its provenance fields and hashes."
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.api.container_definitions)[0]), "command")
    error_message = "The staging task must use the image entrypoint for migrations."
  }

  assert {
    condition = alltrue([
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "POSTGRES_SSL"]) == "true",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "POSTGRES_SSL_CA_PATH"]) == "/etc/ssl/certs/aws-rds-global-bundle.pem",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "SENTRY_ENVIRONMENT"]) == "staging",
      one([for value in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : value.value if value.name == "SENTRY_RELEASE"]) == var.api_image_tag,
      aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "X86_64",
      aws_ecs_task_definition.api.runtime_platform[0].operating_system_family == "LINUX",
      aws_lb_target_group.api.health_check[0].path == "/health/ready",
      aws_lb_target_group.api.health_check[0].matcher == "200",
      aws_db_instance.main.deletion_protection == var.enable_deletion_protection,
      aws_db_instance.main.skip_final_snapshot == var.skip_final_snapshot,
      aws_db_instance.main.final_snapshot_identifier == "dadamjang-staging-postgres-final",
      aws_ecs_service.api.task_definition == aws_ecs_task_definition.api.arn,
    ])
    error_message = "Staging must preserve the task runtime, readiness, RDS recovery, and reviewed revision."
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
    error_message = "The staging runtime secret contract must remain complete."
  }

  assert {
    condition = alltrue([
      var.enable_deletion_protection,
      !var.skip_final_snapshot,
      var.final_snapshot_identifier == null,
      length(var.alarm_action_arns) == 0,
      aws_cloudwatch_metric_alarm.api_cpu.metric_name == "CPUUtilization",
      aws_cloudwatch_metric_alarm.api_memory.metric_name == "MemoryUtilization",
      aws_cloudwatch_metric_alarm.api_alb_5xx.metric_name == "HTTPCode_ELB_5XX_Count",
      aws_cloudwatch_metric_alarm.api_unhealthy_hosts.metric_name == "UnHealthyHostCount",
      aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.metric_name == "HealthyHostCount",
      length(aws_cloudwatch_metric_alarm.api_cpu.alarm_actions) == 0,
      length(aws_cloudwatch_metric_alarm.api_memory.alarm_actions) == 0,
      length(aws_cloudwatch_metric_alarm.api_alb_5xx.alarm_actions) == 0,
      length(aws_cloudwatch_metric_alarm.api_unhealthy_hosts.alarm_actions) == 0,
      length(aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.alarm_actions) == 0,
      contains(keys(aws_cloudwatch_metric_alarm.api_alb_5xx.dimensions), "LoadBalancer"),
      contains(keys(aws_cloudwatch_metric_alarm.api_unhealthy_hosts.dimensions), "LoadBalancer"),
      contains(keys(aws_cloudwatch_metric_alarm.api_unhealthy_hosts.dimensions), "TargetGroup"),
      contains(keys(aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.dimensions), "LoadBalancer"),
      contains(keys(aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.dimensions), "TargetGroup"),
    ])
    error_message = "Staging alarms must retain conservative defaults, metrics, actions, and dimensions."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement) == 1 &&
      toset(keys(jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0])) == toset(["Action", "Condition", "Effect", "Principal"]) &&
      jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Effect == "Allow" &&
      toset(keys(jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Principal)) == toset(["Federated"]) &&
      jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Principal.Federated == data.aws_iam_openid_connect_provider.github_actions.arn &&
      toset(keys(jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Condition)) == toset(["StringEquals"]) &&
      toset(keys(jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Condition.StringEquals)) == toset([
        "token.actions.githubusercontent.com:aud",
        "token.actions.githubusercontent.com:sub",
      ]) &&
      jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      jsondecode(aws_iam_role.github_api_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:${var.github_repository}:environment:${var.environment}"
    )
    error_message = "Staging OIDC trust must contain only the exact environment-scoped GitHub statement."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement) == 7 &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[0])) == toset(["Action", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[0].Action == "ecr:GetAuthorizationToken" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[0].Resource == "*" &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[1])) == toset(["Action", "Effect", "Resource"]) &&
      toset(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[1].Action) == toset([
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[1].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[1].Resource == aws_ecr_repository.api.arn &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[2])) == toset(["Action", "Effect", "Resource"]) &&
      toset(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[2].Action) == toset(["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[2].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[2].Resource == "*" &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[3])) == toset(["Action", "Effect", "Resource"]) &&
      toset(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[3].Action) == toset(["ecs:DescribeServices", "ecs:UpdateService"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[3].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[3].Resource == aws_ecs_service.api.id &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4])) == toset(["Action", "Condition", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Action == "ecs:RunTask" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Resource == "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.api.family}:*" &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Condition)) == toset(["ArnEquals"]) &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Condition.ArnEquals)) == toset(["ecs:cluster"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[4].Condition.ArnEquals["ecs:cluster"] == aws_ecs_cluster.main.arn &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[5])) == toset(["Action", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[5].Action == "ecs:DescribeTasks" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[5].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[5].Resource == "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.main.name}/*" &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6])) == toset(["Action", "Condition", "Effect", "Resource"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Action == "iam:PassRole" &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Effect == "Allow" &&
      toset(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Resource) == toset([aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn]) &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Condition)) == toset(["StringEquals"]) &&
      toset(keys(jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Condition.StringEquals)) == toset(["iam:PassedToService"]) &&
      jsondecode(aws_iam_role_policy.github_api_deploy.policy).Statement[6].Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com"
    )
    error_message = "Staging deployment IAM must contain exactly the reviewed action, resource, and condition pairings."
  }
}

run "alarm_action_override" {
  command = apply

  variables {
    acm_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alarm_action_arns   = ["arn:aws:sns:ap-northeast-2:123456789012:dadamjang-staging-alerts"]
    api_hostname        = "api.staging.example.test"
  }

  assert {
    condition = alltrue([
      toset(aws_cloudwatch_metric_alarm.api_cpu.alarm_actions) == toset(var.alarm_action_arns),
      toset(aws_cloudwatch_metric_alarm.api_memory.alarm_actions) == toset(var.alarm_action_arns),
      toset(aws_cloudwatch_metric_alarm.api_alb_5xx.alarm_actions) == toset(var.alarm_action_arns),
      toset(aws_cloudwatch_metric_alarm.api_unhealthy_hosts.alarm_actions) == toset(var.alarm_action_arns),
      toset(aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.alarm_actions) == toset(var.alarm_action_arns),
    ])
    error_message = "Every staging alarm must receive a non-empty alarm action override."
  }

  assert {
    condition = (
      toset(keys(aws_cloudwatch_metric_alarm.api_cpu.dimensions)) == toset(["ClusterName", "ServiceName"]) &&
      aws_cloudwatch_metric_alarm.api_cpu.dimensions.ClusterName == aws_ecs_cluster.main.name &&
      aws_cloudwatch_metric_alarm.api_cpu.dimensions.ServiceName == aws_ecs_service.api.name &&
      toset(keys(aws_cloudwatch_metric_alarm.api_memory.dimensions)) == toset(["ClusterName", "ServiceName"]) &&
      aws_cloudwatch_metric_alarm.api_memory.dimensions.ClusterName == aws_ecs_cluster.main.name &&
      aws_cloudwatch_metric_alarm.api_memory.dimensions.ServiceName == aws_ecs_service.api.name &&
      toset(keys(aws_cloudwatch_metric_alarm.api_alb_5xx.dimensions)) == toset(["LoadBalancer"]) &&
      aws_cloudwatch_metric_alarm.api_alb_5xx.dimensions.LoadBalancer == aws_lb.api.arn_suffix &&
      toset(keys(aws_cloudwatch_metric_alarm.api_unhealthy_hosts.dimensions)) == toset(["LoadBalancer", "TargetGroup"]) &&
      aws_cloudwatch_metric_alarm.api_unhealthy_hosts.dimensions.LoadBalancer == aws_lb.api.arn_suffix &&
      aws_cloudwatch_metric_alarm.api_unhealthy_hosts.dimensions.TargetGroup == aws_lb_target_group.api.arn_suffix &&
      toset(keys(aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.dimensions)) == toset(["LoadBalancer", "TargetGroup"]) &&
      aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.dimensions.LoadBalancer == aws_lb.api.arn_suffix &&
      aws_cloudwatch_metric_alarm.api_zero_healthy_hosts.dimensions.TargetGroup == aws_lb_target_group.api.arn_suffix
    )
    error_message = "Staging alarms must keep their exact ECS and ALB dimension values."
  }
}

run "final_snapshot_identifier_override" {
  command = apply

  variables {
    acm_certificate_arn       = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    api_hostname              = "api.staging.example.test"
    final_snapshot_identifier = "dadamjang-reviewed-final"
  }

  assert {
    condition     = aws_db_instance.main.final_snapshot_identifier == "dadamjang-reviewed-final"
    error_message = "Staging RDS must preserve an explicit final snapshot identifier override."
  }
}
