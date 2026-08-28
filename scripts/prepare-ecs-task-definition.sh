#!/usr/bin/env bash

set -euo pipefail

terraform_root="$1"
output="$2"
canonical_task_definition_arn=$(terraform -chdir="$terraform_root" output -raw ecs_task_definition_arn)
deployed_task_definition_arn=$(aws ecs describe-services \
  --cluster "$AWS_ECS_CLUSTER" \
  --services "$AWS_ECS_SERVICE" \
  --query 'services[0].taskDefinition' \
  --output text)

for task_definition_arn in "$canonical_task_definition_arn" "$deployed_task_definition_arn"; do
  if [[ ! "$task_definition_arn" =~ ^arn:[^:]+:ecs:[^:]+:[0-9]{12}:task-definition/[^:]+:[0-9]+$ ]]; then
    printf 'Invalid ECS task definition ARN: %s\n' "$task_definition_arn" >&2
    exit 1
  fi
done

canonical_json=$(mktemp)
deployed_json=$(mktemp)
prepared_json=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$canonical_json" "$deployed_json" "$prepared_json"' EXIT

aws ecs describe-task-definition \
  --task-definition "$canonical_task_definition_arn" \
  --output json >"$canonical_json"
aws ecs describe-task-definition \
  --task-definition "$deployed_task_definition_arn" \
  --output json >"$deployed_json"

validation_filter='
  .taskDefinition.containerDefinitions
  | map(select(.name == "api"))
  | if length != 1 then error("expected exactly one api container") else .[0] end
  | (.environment // []) as $environment
  | (.secrets // []) as $secrets
  | ($environment | map(.name)) as $environment_names
  | ($secrets | map(.name)) as $secret_names
  | ($environment | map({ key: .name, value: .value }) | from_entries) as $env
  | if ($environment_names | length) != ($environment_names | unique | length) then error("duplicate environment name")
    elif ($secret_names | length) != ($secret_names | unique | length) then error("duplicate secret name")
    elif ($environment | any((.name | type) != "string" or (.name | length) == 0 or (.value | type) != "string" or (.value | length) == 0)) then error("invalid environment entry")
    elif ($secrets | any((.name | type) != "string" or (.name | length) == 0 or (.valueFrom | type) != "string" or (.valueFrom | length) == 0)) then error("invalid secret entry")
    elif $env.NODE_ENV != "production" then error("NODE_ENV must be production")
    elif $env.POSTGRES_SSL != "true" then error("POSTGRES_SSL must be true")
    elif $env.POSTGRES_SSL_CA_PATH != "/etc/ssl/certs/aws-rds-global-bundle.pem" then error("wrong PostgreSQL CA path")
    elif ($env.SENTRY_RELEASE | type) != "string" or ($env.SENTRY_RELEASE | length) == 0 then error("missing SENTRY_RELEASE")
    elif ($secret_names | index("POSTGRES_PASSWORD")) == null then error("missing POSTGRES_PASSWORD secret")
    else true
    end
'

for task_definition in "$canonical_json" "$deployed_json"; do
  if ! jq -e "$validation_filter" "$task_definition" >/dev/null; then
    printf 'ECS task definition runtime contract validation failed\n' >&2
    exit 1
  fi
done

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
if [[ "$deployed_contract" != "$canonical_contract" ]]; then
  printf 'Deployed ECS task definition drifted from the Terraform runtime contract\n' >&2
  exit 1
fi

jq '.taskDefinition' "$deployed_json" >"$prepared_json"
mv "$prepared_json" "$output"
