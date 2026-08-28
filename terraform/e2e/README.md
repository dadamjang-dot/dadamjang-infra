# e2e Terraform

Isolated AWS root for mobile automation. It owns the `dadamjang_e2e` PostgreSQL database, Redis, ECR repository, ECS API, public HTTPS ALB, runtime secret container, and mobile CI OIDC role. It does not read staging state or staging resources.

## Prerequisites

1. Create the GitHub Actions OIDC provider `https://token.actions.githubusercontent.com` once in the AWS account.
2. Issue an ACM certificate in `aws_region` and create DNS for `api_hostname` targeting `api_alb_dns_name`.
3. Supply the root's declared `remote` backend with an e2e-only partial backend configuration containing only `hostname`, `organization`, and `workspaces`. Configure that HCP Terraform workspace with **Execution Mode = Local** before initialization, then apply with separate e2e remote state. Never reuse the staging workspace.
4. Put the required JSON keys from `local.runtime_secret_keys` into Secrets Manager secret `dadamjang-e2e/api-runtime`. The e2e task runs the same backend image as staging, so its shared runtime keys stay synchronized while values remain environment-specific. Terraform creates only the empty secret container; values never enter Terraform state or outputs.
5. Push an immutable backend image to `api_ecr_repository_url`, then apply with its tag as `api_image_tag`.
6. The backend image must provide `pnpm e2e:reset`. The command must reject any run unless `NODE_ENV=e2e` and `POSTGRES_DATABASE=dadamjang_e2e`; the task definition fixes both values.
7. Create the `mobile-e2e` GitHub Environment in `dadamjang-dot/dadamjang-fe`. Restrict deployment branches to trusted same-repository branches and deny fork pull requests. Store outputs as repository/environment variables; no static AWS credentials or runtime secrets are needed.

## Mobile workflow contract

Use workflow/job concurrency with cancellation to serialize the shared database:

```yaml
concurrency:
  group: mobile-e2e
  cancel-in-progress: true
```

The AWS job must use `environment: mobile-e2e`, `permissions: { contents: read, id-token: write }`, and a trusted-context condition that rejects fork pull requests before credential configuration. The interface is exact:

| Mobile CI variable | Terraform output | Secret |
| --- | --- | --- |
| `E2E_AWS_ROLE_ARN` | `e2e_aws_role_arn` | No |
| `E2E_API_URL` | `e2e_api_url` | No |
| `E2E_AWS_REGION` | `e2e_aws_region` | No |
| `AWS_ECS_CLUSTER` | `ecs_cluster_name` | No |
| `AWS_ECS_SERVICE` | `ecs_service_name` | No |
| `AWS_ECS_TASK_DEFINITION` | `ecs_task_definition_arn` | No |
| `AWS_PRIVATE_SUBNET_IDS` | `private_subnet_ids_csv` | No |
| `AWS_API_SECURITY_GROUP_ID` | `api_security_group_id` | No |

`private_subnet_ids` remains available as a Terraform list for non-GitHub consumers. Do not export `api_runtime` or RDS credential secret values to mobile CI.

Before Maestro, scale the API to one and wait for stability:

```bash
aws ecs update-service --cluster "$AWS_ECS_CLUSTER" --service "$AWS_ECS_SERVICE" --desired-count 1 >/dev/null
aws ecs wait services-stable --cluster "$AWS_ECS_CLUSTER" --services "$AWS_ECS_SERVICE"
```

Reset only through a one-off ECS task. Do not add an HTTP or GraphQL reset endpoint:

```bash
task_arn=$(aws ecs run-task \
  --cluster "$AWS_ECS_CLUSTER" \
  --task-definition "$AWS_ECS_TASK_DEFINITION" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$AWS_PRIVATE_SUBNET_IDS],securityGroups=[$AWS_API_SECURITY_GROUP_ID],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["pnpm","e2e:reset"],"environment":[{"name":"NODE_ENV","value":"e2e"},{"name":"POSTGRES_DATABASE","value":"dadamjang_e2e"}]}]}' \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --cluster "$AWS_ECS_CLUSTER" --tasks "$task_arn"
test "$(aws ecs describe-tasks --cluster "$AWS_ECS_CLUSTER" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)" = 0
```

The mobile workflow owns Maestro and artifact upload. Upload logs/screenshots before cleanup with `if: always()`. The final cleanup step must also use `if: always()`:

```bash
aws ecs update-service --cluster "$AWS_ECS_CLUSTER" --service "$AWS_ECS_SERVICE" --desired-count 0 >/dev/null
```
