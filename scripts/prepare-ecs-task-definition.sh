#!/usr/bin/env bash

set -euo pipefail

terraform_root="$1"
output="$2"

if [[ ! "$IMAGE_REFERENCE" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  printf 'Invalid immutable image reference: %s\n' "$IMAGE_REFERENCE" >&2
  exit 1
fi
if [[ ! "$SENTRY_RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  printf 'Invalid Sentry release: %s\n' "$SENTRY_RELEASE" >&2
  exit 1
fi

release_contract=$(terraform -chdir="$terraform_root" output -json ecs_release_contract)
if ! jq -e '
  type == "object" and
  (keys | sort) == [
    "canonical_task_definition_arn",
    "image_repository",
    "observed_service_task_definition_arn",
    "runtime_secret_names",
    "source_hashes",
    "task_family"
  ] and
  (.source_hashes | keys | sort) == ["application.tf", "locals.tf", "outputs.tf", "variables.tf"] and
  (.runtime_secret_names | type) == "array"
' >/dev/null <<<"$release_contract"; then
  printf 'Invalid Terraform ECS release contract\n' >&2
  exit 1
fi

canonical_task_definition_arn=$(jq -er '.canonical_task_definition_arn' <<<"$release_contract")
observed_service_task_definition_arn=$(jq -er '.observed_service_task_definition_arn' <<<"$release_contract")
task_family=$(jq -er '.task_family' <<<"$release_contract")
image_repository=$(jq -er '.image_repository' <<<"$release_contract")
runtime_secret_names=$(jq -cS '.runtime_secret_names | sort' <<<"$release_contract")

if [[ ! "$task_family" =~ ^[A-Za-z0-9_-]{1,255}$ ]]; then
  printf 'Invalid Terraform ECS task family: %s\n' "$task_family" >&2
  exit 1
fi
if [[ "${IMAGE_REFERENCE%@sha256:*}" != "$image_repository" ]]; then
  printf 'Image repository does not match the Terraform ECS contract\n' >&2
  exit 1
fi

for source_file in application.tf locals.tf outputs.tf variables.tf; do
  expected_hash=$(jq -er --arg source_file "$source_file" '.source_hashes[$source_file]' <<<"$release_contract")
  actual_hash=$(sha256sum "$terraform_root/$source_file" | awk '{print $1}')
  if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ || "$actual_hash" != "$expected_hash" ]]; then
    printf 'Terraform state is stale for %s\n' "$source_file" >&2
    exit 1
  fi
done

task_definition_arn_pattern="^arn:[^:]+:ecs:[^:]+:[0-9]{12}:task-definition/${task_family}:[1-9][0-9]*$"
for task_definition_arn in "$canonical_task_definition_arn" "$observed_service_task_definition_arn"; do
  if [[ ! "$task_definition_arn" =~ $task_definition_arn_pattern ]]; then
    printf 'Invalid ECS task definition ARN: %s\n' "$task_definition_arn" >&2
    exit 1
  fi
done

service_json=$(mktemp)
canonical_json=$(mktemp)
deployed_json=$(mktemp)
prepared_json=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$service_json" "$canonical_json" "$deployed_json" "$prepared_json"' EXIT

aws ecs describe-services \
  --cluster "$AWS_ECS_CLUSTER" \
  --services "$AWS_ECS_SERVICE" \
  --output json >"$service_json"

if ! deployed_task_definition_arn=$(jq -er --arg service "$AWS_ECS_SERVICE" '
  if ((.failures // []) | length) != 0 then error("service lookup failed")
  elif (.services | length) != 1 then error("expected exactly one service")
  elif .services[0].serviceName != $service then error("wrong service")
  elif .services[0].status != "ACTIVE" then error("service is not active")
  else .services[0].taskDefinition
  end
' "$service_json"); then
  printf 'Failed to resolve the exact active ECS service revision\n' >&2
  exit 1
fi
if [[ ! "$deployed_task_definition_arn" =~ $task_definition_arn_pattern ]]; then
  printf 'Invalid deployed ECS task definition ARN: %s\n' "$deployed_task_definition_arn" >&2
  exit 1
fi

aws ecs describe-task-definition \
  --task-definition "$canonical_task_definition_arn" \
  --output json >"$canonical_json"
aws ecs describe-task-definition \
  --task-definition "$deployed_task_definition_arn" \
  --output json >"$deployed_json"

base_validation_filter='
  . as $document
  | .taskDefinition as $task
  | ($arn | split(":")) as $task_arn
  | ($task_arn[1]) as $partition
  | ($task_arn[4]) as $account
  | if $task.taskDefinitionArn != $arn then error("task definition response ARN mismatch")
    elif $task.family != $family then error("wrong task family")
    elif $task.status != "ACTIVE" then error("task definition is not active")
    elif $task.networkMode != "awsvpc" then error("wrong network mode")
    elif (($task.requiresCompatibilities // []) | sort) != ["FARGATE"] then error("wrong launch compatibility")
    elif (($task.taskRoleArn | type) != "string" or ($task.taskRoleArn | startswith("arn:\($partition):iam::\($account):role/") | not)) then error("wrong task role")
    elif (($task.executionRoleArn | type) != "string" or ($task.executionRoleArn | startswith("arn:\($partition):iam::\($account):role/") | not)) then error("wrong execution role")
    elif ($task.containerDefinitions | length) != 1 or $task.containerDefinitions[0].name != "api" then error("expected exactly one api container")
    else $task.containerDefinitions[0]
    end
  | (.environment // []) as $environment
  | (.secrets // []) as $secrets
  | ($environment | map(.name)) as $environment_names
  | ($secrets | map(.name)) as $secret_names
  | if ($environment_names | length) != ($environment_names | unique | length) then error("duplicate environment name")
    elif ($secret_names | length) != ($secret_names | unique | length) then error("duplicate secret name")
    elif ($environment | any((.name | type) != "string" or (.name | length) == 0 or (.value | type) != "string" or (.value | length) == 0)) then error("invalid environment entry")
    elif ($secrets | any((.name | type) != "string" or (.name | length) == 0 or (.valueFrom | type) != "string" or (.valueFrom | length) == 0)) then error("invalid secret entry")
    else $document
    end
'

if ! jq -e --arg arn "$deployed_task_definition_arn" --arg family "$task_family" "$base_validation_filter" "$deployed_json" >/dev/null; then
  printf 'Deployed ECS task definition identity validation failed\n' >&2
  exit 1
fi

canonical_validation_filter="$base_validation_filter"'
  | .taskDefinition as $task
  | $task.containerDefinitions[0] as $api
  | ($api.environment | map({ key: .name, value: .value }) | from_entries) as $env
  | ($api.secrets | map(.name) | sort) as $secret_names
  | if $api.essential != true then error("api container is not essential")
    elif $env.NODE_ENV != "production" then error("NODE_ENV must be production")
    elif $env.POSTGRES_SSL != "true" then error("POSTGRES_SSL must be true")
    elif $env.POSTGRES_SSL_CA_PATH != "/etc/ssl/certs/aws-rds-global-bundle.pem" then error("wrong PostgreSQL CA path")
    elif ($env.SENTRY_RELEASE | type) != "string" or ($env.SENTRY_RELEASE | length) == 0 then error("missing SENTRY_RELEASE")
    elif $secret_names != $runtime_secret_names then error("wrong runtime secret set")
    elif $task.runtimePlatform.cpuArchitecture != "X86_64" then error("wrong CPU architecture")
    elif $task.runtimePlatform.operatingSystemFamily != "LINUX" then error("wrong operating system")
    else true
    end
'
if ! jq -e \
  --arg arn "$canonical_task_definition_arn" \
  --arg family "$task_family" \
  --argjson runtime_secret_names "$runtime_secret_names" \
  "$canonical_validation_filter" \
  "$canonical_json" >/dev/null; then
  printf 'Canonical ECS task definition runtime contract validation failed\n' >&2
  exit 1
fi

contract_filter='
  .taskDefinition
  | del(
      .taskDefinitionArn,
      .revision,
      .status,
      .requiresAttributes,
      .compatibilities,
      .registeredAt,
      .registeredBy,
      .deregisteredAt,
      .tags
    )
  | .containerDefinitions |= (
      map(
        .environment = ((.environment // []) | sort_by(.name))
        | .secrets = ((.secrets // []) | sort_by(.name))
        | if .name == "api" then
            del(.image)
            | .environment |= map(select(.name != "SENTRY_RELEASE"))
          else .
          end
      )
      | sort_by(.name)
    )
  | .requiresCompatibilities = ((.requiresCompatibilities // []) | sort)
  | .placementConstraints = ((.placementConstraints // []) | sort_by(.type, .expression))
  | .volumes = ((.volumes // []) | sort_by(.name))
'

canonical_contract=$(jq -cS "$contract_filter" "$canonical_json")
deployed_contract=$(jq -cS "$contract_filter" "$deployed_json")
if [[ "$deployed_contract" != "$canonical_contract" && "$deployed_task_definition_arn" != "$observed_service_task_definition_arn" ]]; then
  printf 'ECS contract transition does not start from the Terraform-observed service revision\n' >&2
  exit 1
fi

jq \
  --arg image "$IMAGE_REFERENCE" \
  --arg sentry_release "$SENTRY_RELEASE" \
  '.taskDefinition
  | .containerDefinitions |= map(
      if .name == "api" then
        .image = $image
        | .environment |= map(if .name == "SENTRY_RELEASE" then .value = $sentry_release else . end)
      else .
      end
    )' \
  "$canonical_json" >"$prepared_json"
mv "$prepared_json" "$output"
