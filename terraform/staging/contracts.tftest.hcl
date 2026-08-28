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
}

run "release_contracts" {
  command = plan

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
}
