# dadamjang infra

다담장 플랫폼의 로컬 개발 의존성, staging/e2e AWS 인프라, CI/CD 설정을 관리한다.

## 구성

- local: PostgreSQL 16, Redis 7, MinIO, Mailpit
- staging: AWS VPC, ALB, ECS Fargate API, RDS PostgreSQL, ElastiCache Redis, ECR, Secrets Manager, CloudWatch
- e2e: staging과 분리된 AWS VPC, `dadamjang_e2e` RDS PostgreSQL, Redis, ECS Fargate API, ECR, Secrets Manager, HTTPS ALB
- image: Cloudflare R2 원본 저장 + Cloudflare Images 변환. AWS S3와 CloudFront는 사용하지 않는다.
- environment: `staging`과 `e2e`를 별도 Terraform root/state로 선언한다. production Terraform root는 만들지 않는다.

## 로컬 실행

```bash
cp .env.example .env
docker compose up -d
docker compose ps
```

| 서비스 | 주소 | 용도 |
| --- | --- | --- |
| PostgreSQL | `localhost:5432` | 애플리케이션 DB |
| Redis | `localhost:6379` | 캐시·세션·큐 개발용 |
| MinIO API | `http://localhost:9000` | S3 호환 로컬 이미지 저장소 |
| MinIO Console | `http://localhost:9001` | MinIO 관리 UI |
| Mailpit SMTP | `localhost:1025` | 로컬 메일 수신 |
| Mailpit UI | `http://localhost:8025` | 수신 메일 확인 |

종료는 `docker compose down`, 데이터까지 삭제하려면 `docker compose down -v`를 사용한다.

BE 로컬 환경은 `POSTGRES_HOST=localhost`, `POSTGRES_PORT=5432`, `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres`, `POSTGRES_DATABASE=dadamjang`을 사용한다. Mailpit은 `localhost:1025` SMTP로 연결한다.

## staging Terraform

```bash
cd terraform/staging
terraform init -backend=false
terraform fmt -recursive
terraform validate
terraform plan
```

`terraform apply`는 실행하지 않는다. GitHub `staging` Environment 승인 후 `terraform-apply.yml`을 수동 실행한다.

상태 파일은 Git에 저장하지 않는다. AWS S3를 사용하지 않기 위해 HCP Terraform 또는 조직의 기존 원격 backend를 권장한다. `TF_BACKEND_CONFIG` GitHub Environment secret에 backend 설정을 HCL로 넣는다.

```hcl
# 예: HCP Terraform remote backend 설정
organization = "your-terraform-cloud-organization"

workspaces {
  name = "dadamjang-staging"
}
```

현재 root module은 backend block을 고정하지 않는다. CI가 위 설정을 `backend.hcl`로 전달한다. 로컬에서 원격 state를 쓸 때도 같은 backend 설정 파일을 사용한다.

첫 Terraform apply는 ECS service를 `desired_count = 0`으로 만든다. 아직 ECR 이미지가 없어서다. 이후 `api-deploy.yml`이 첫 이미지를 push하고 service를 1개 task로 시작한다. Terraform은 CI가 관리하는 task definition과 desired count를 덮어쓰지 않는다.

ALB health check는 backend의 현재 GraphQL endpoint(`/graphql`)에 맞춰 `200-499`를 정상으로 취급한다. BE에 전용 `200` health endpoint가 생기면 matcher를 `200`으로 좁혀야 한다.

## AWS 사전 준비

1. AWS 계정에서 GitHub Actions OIDC provider `https://token.actions.githubusercontent.com`를 1회 생성한다. Terraform의 `data.aws_iam_openid_connect_provider.github_actions`가 이를 참조한다.
2. AWS 자격 증명으로 Terraform을 1회 apply한다. 계정 ID는 코드에 넣지 않는다.
3. output에서 아래 값을 GitHub `dadamjang-dot/dadamjang-infra`의 `staging` Environment에 등록한다.

| 이름 | 종류 | 값 |
| --- | --- | --- |
| `AWS_REGION` | Variable | `ap-northeast-2` 또는 적용 region |
| `AWS_ECR_REPOSITORY` | Variable | `api_ecr_repository_url`의 repository 이름 부분 |
| `AWS_ECS_CLUSTER` | Variable | `ecs_cluster_name` |
| `AWS_ECS_SERVICE` | Variable | `ecs_service_name` |
| `AWS_ECS_TASK_FAMILY` | Variable | `ecs_task_family` |
| `AWS_API_DEPLOY_ROLE_ARN` | Secret | `github_api_deploy_role_arn` |
| `AWS_TERRAFORM_ROLE_ARN` | Secret | staging Terraform 권한을 가진 별도 OIDC role ARN |
| `TF_BACKEND_CONFIG` | Secret | 원격 Terraform state backend HCL |

API deploy role은 ECR image 확인/업로드, ECS task definition 등록, migration task 실행, service 갱신에 필요한 권한만 허용한다. Terraform role은 별도로 만들고 AWS resource provisioning에 필요한 최소 권한만 부여한다. `staging` Environment는 배포 branch를 `main`으로만 제한하고 Required reviewers와 Prevent self-review를 설정해 배포자가 자신의 배포를 승인할 수 없게 한다. Terraform apply와 API deploy는 이 보호 규칙을 설정한 뒤 사용한다.

현재 `staging` Environment variables는 아래 기본 naming으로 등록되어 있다.

```txt
AWS_REGION=ap-northeast-2
AWS_ECR_REPOSITORY=dadamjang-staging-api
AWS_ECS_CLUSTER=dadamjang-staging-cluster
AWS_ECS_SERVICE=dadamjang-staging-api
AWS_ECS_TASK_FAMILY=dadamjang-staging-api
```

아래 secrets는 실제 AWS 계정과 원격 Terraform backend 값이 있어야 등록할 수 있다.

```txt
AWS_API_DEPLOY_ROLE_ARN
AWS_TERRAFORM_ROLE_ARN
TF_BACKEND_CONFIG
```

## API runtime secrets

Terraform은 Secrets Manager secret 컨테이너만 만든다. 비밀값은 Terraform 변수나 Git에 넣지 않는다. apply 후 `api_runtime_secret_arn`에 JSON secret을 등록한다.

```json
{
  "API_PUBLIC_BASE_URL": "https://api.staging.example.com",
  "CLIENT_URL": "https://staging.example.com",
  "DADAMJANG_BO_URL": "https://bo.staging.example.com",
  "IDENTITY_CI_PEPPER": "replace-me",
  "IDENTITY_INICIS_API_KEY": "replace-me",
  "IDENTITY_INICIS_CALLBACK_BASE_URL": "https://api.staging.example.com",
  "IDENTITY_INICIS_MID": "replace-me",
  "IDENTITY_INICIS_SEED_IV": "replace-me",
  "JWT_ACCESS_TOKEN_EXP": "15m",
  "JWT_ACCESS_TOKEN_SECRET": "replace-me",
  "JWT_REFRESH_TOKEN_EXP": "7d",
  "JWT_REFRESH_TOKEN_SECRET": "replace-me",
  "EMAIL_CODE_PEPPER": "replace-me",
  "KAKAO_CLIENT_ID": "replace-me",
  "KAKAO_CALLBACK_URL": "https://api.staging.example.com/api/auth/kakao/callback",
  "RESEND_API_KEY": "replace-me",
  "RESEND_FROM_EMAIL": "no-reply@example.com",
  "CLOUDFLARE_R2_ENDPOINT": "https://<account-id>.r2.cloudflarestorage.com",
  "CLOUDFLARE_R2_ACCESS_KEY_ID": "replace-me",
  "CLOUDFLARE_R2_SECRET_ACCESS_KEY": "replace-me",
  "CLOUDFLARE_R2_BUCKET": "dadamjang-staging",
  "CLOUDFLARE_R2_PUBLIC_BASE_URL": "https://images.example.com",
  "CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL": "https://imagedelivery.net/<account-hash>"
}
```

새 task definition을 등록하기 전에 위 JSON의 모든 key를 실제 값으로 새 secret version에 등록해야 한다. Terraform은 JSON 값이 아니라 key별 ECS 참조만 추가하므로, 누락된 key가 있으면 새 task가 시작되지 않는다. OIDC trust 변경을 먼저 Terraform apply한 뒤 API deploy를 실행한다.

예시 JSON을 실제 값으로 저장한 뒤 다음처럼 등록한다.

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform -chdir=terraform/staging output -raw api_runtime_secret_arn)" \
  --secret-string file://runtime-secrets.json
```

Cloudflare에서는 R2 bucket, S3 API token(해당 bucket read/write만), public delivery base URL, Cloudflare Images transform base URL을 만든다. Cloudflare access key, secret key, account endpoint는 GitHub secret이 아니라 위 AWS Secrets Manager JSON에만 저장한다.

## GitHub Actions

- `infra-ci.yml`: infra PR/main 변경 시 Compose config, Terraform fmt, Terraform validate를 수행한다. state backend 없이 validate한다.
- `terraform-apply.yml`: 수동 실행만 가능하다. `staging` Environment 승인 후 plan 또는 apply한다.
- `api-deploy.yml`: `repository_dispatch` 타입 `backend-main` 또는 수동 실행으로 BE를 lint/test/build하고 ECR push, ECS deploy를 수행한다. deploy job은 `staging` Environment 승인을 요구한다.

API deploy는 test job이 확정한 backend commit만 다시 checkout한다. Image tag `backend-<backend-sha>-dockerfile-<dockerfile-blob-sha>`는 테스트한 backend source와 infra가 소유한 Docker build definition을 함께 식별하며, 같은 tag가 ECR에 있으면 기존 immutable image를 재사용한다.

`dadamjang-be`의 main merge가 deploy를 자동 시작하려면 BE workflow가 infra repository에 dispatch를 보내야 한다. infra workflow만으로는 다른 repository의 main push를 구독할 수 없다.

```yaml
# dadamjang-be/.github/workflows/deploy-dispatch.yml에 추가할 계약
- name: Trigger infrastructure deployment
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_REPOSITORY_DISPATCH_TOKEN }}
    repository: dadamjang-dot/dadamjang-infra
    event-type: backend-main
    client-payload: '{"ref":"${{ github.sha }}"}'
```

`INFRA_REPOSITORY_DISPATCH_TOKEN`은 `dadamjang-infra`에만 dispatch 권한을 가진 fine-grained token으로 제한한다.

## 검증

```bash
docker compose --env-file .env.example config
terraform -chdir=terraform/staging fmt -check -recursive
terraform -chdir=terraform/staging init -backend=false -input=false
terraform -chdir=terraform/staging validate
```
