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

if ! primary_deployments=$(aws ecs describe-services \
  --cluster "$AWS_ECS_CLUSTER" \
  --services "$AWS_ECS_SERVICE" \
  --query 'services[0].deployments[?status==`PRIMARY`].{taskDefinition:taskDefinition,rolloutState:rolloutState}' \
  --output json); then
  printf 'Failed to inspect the ECS service deployment\n' >&2
  exit 1
fi

if ! jq -e 'type == "array"' >/dev/null <<< "$primary_deployments"; then
  printf 'ECS returned an invalid PRIMARY deployment response\n' >&2
  exit 1
fi

primary_count=$(jq 'length' <<< "$primary_deployments")
if [[ "$primary_count" != "1" ]]; then
  printf 'Expected one PRIMARY ECS deployment, found %s\n' "$primary_count" >&2
  exit 1
fi

deployed_task_definition=$(jq -r '.[0].taskDefinition // empty' <<< "$primary_deployments")
rollout_state=$(jq -r '.[0].rolloutState // empty' <<< "$primary_deployments")
if [[ "$deployed_task_definition" != "$TASK_DEFINITION_ARN" || "$rollout_state" != "COMPLETED" ]]; then
  printf 'ECS rollout verification failed: task definition %s, rollout state %s\n' \
    "$deployed_task_definition" "$rollout_state" >&2
  exit 1
fi
