#!/usr/bin/env bash

set -euo pipefail

network_config=$(aws ecs describe-services \
  --cluster "$AWS_ECS_CLUSTER" \
  --service "$AWS_ECS_SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' \
  --output json)

run_task_input=$(jq -n \
  --arg cluster "$AWS_ECS_CLUSTER" \
  --arg task_definition "$TASK_DEFINITION_ARN" \
  --argjson network "$network_config" \
  '{
    cluster: $cluster,
    taskDefinition: $task_definition,
    launchType: "FARGATE",
    networkConfiguration: {
      awsvpcConfiguration: {
        subnets: $network.subnets,
        securityGroups: $network.securityGroups,
        assignPublicIp: "DISABLED"
      }
    },
    overrides: {
      containerOverrides: [{
        name: "api",
        command: ["node", "dist/scripts/migrate.js"]
      }]
    }
  }')

task_arn=$(aws ecs run-task \
  --cli-input-json "$run_task_input" \
  --query 'tasks[0].taskArn' \
  --output text)

aws ecs wait tasks-stopped --cluster "$AWS_ECS_CLUSTER" --tasks "$task_arn"
exit_code=$(aws ecs describe-tasks \
  --cluster "$AWS_ECS_CLUSTER" \
  --tasks "$task_arn" \
  --query 'tasks[0].containers[0].exitCode' \
  --output text)

if [[ "$exit_code" != "0" ]]; then
  printf 'Migration failed with exit code %s\n' "$exit_code" >&2
  exit 1
fi

aws ecs update-service \
  --cluster "$AWS_ECS_CLUSTER" \
  --service "$AWS_ECS_SERVICE" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --desired-count 1 >/dev/null
aws ecs wait services-stable --cluster "$AWS_ECS_CLUSTER" --services "$AWS_ECS_SERVICE"
