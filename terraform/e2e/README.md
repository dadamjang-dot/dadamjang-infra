# e2e Terraform

Isolated AWS root for mobile automation. It owns the `dadamjang_e2e` PostgreSQL database, Redis, ECR repository, ECS API, public HTTPS ALB, runtime secret container, and mobile CI OIDC role. It does not read staging state or staging resources.

## Current availability

The root is declarative only. `terraform-apply.yml` currently creates a staging plan and never applies it, and there is no e2e apply workflow. No e2e resources or state-backed outputs exist until reviewed e2e automation is added and completes its protected approval. Do not create `mobile-e2e` values from expected names: `E2E_AWS_REGION`, role, ECS, and API values must come from the outputs below after that automation. Until then the mobile workflows stop before AWS credential configuration with an output-handoff error; use the local Maestro smoke path in `dadamjang-fe/README.md` instead. Manual or out-of-band e2e apply and image push are not allowed.

## Prerequisites

1. Create the GitHub Actions OIDC provider `https://token.actions.githubusercontent.com` once in the AWS account.
2. Issue an ACM certificate in `aws_region` and create DNS for `api_hostname` targeting `api_alb_dns_name`.
3. After reviewed e2e automation is available, supply its declared `remote` backend with an e2e-only partial backend configuration containing only `hostname`, `organization`, and `workspaces`. Configure that HCP Terraform workspace with **Execution Mode = Local**. The automation must use separate e2e state; never reuse the staging workspace.
4. Supply `cloudflare_account_id`, the existing distinct `cloudflare_r2_final_bucket_name`, and a short-lived `CLOUDFLARE_API_TOKEN` with only `Workers R2 Storage Write`. Terraform creates `dadamjang-e2e-pending` with a one-day deletion lifecycle and disabled `r2.dev`; do not attach a public/custom domain.
5. After the reviewed automation creates the secret container, register the required JSON keys from `local.runtime_secret_keys` in `dadamjang-e2e/api-runtime`, including `CLOUDFLARE_R2_PENDING_BUCKET=dadamjang-e2e-pending`. The e2e task runs the same backend image as staging, so its shared runtime keys stay synchronized while values remain environment-specific. Terraform creates only the empty secret container; values never enter Terraform state or outputs. Scope the application R2 S3 credential to Object Read & Write on the exact final+pending bucket names from `r2_application_bucket_names`; never reuse the Terraform provider token.
6. The reviewed e2e automation must publish an immutable backend image to `api_ecr_repository_url` and apply its tag as `api_image_tag`. Do not push or apply it manually.
7. The backend image must provide `pnpm e2e:reset`. The command must reject any run unless `NODE_ENV=e2e` and `POSTGRES_DATABASE=dadamjang_e2e`; the task definition fixes both values.
8. Create the `mobile-e2e` GitHub Environment in `dadamjang-dot/dadamjang-fe`. Restrict deployment branches to trusted same-repository branches and deny fork pull requests. Store outputs as repository/environment variables; no static AWS credentials or runtime secrets are needed.

## Mobile workflow contract

Use FIFO workflow/job concurrency to serialize the shared database without cancelling an active cleanup:

```yaml
concurrency:
  group: mobile-e2e
  cancel-in-progress: false
  queue: max
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
