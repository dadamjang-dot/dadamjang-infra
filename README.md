# dadamjang infra

다담장 플랫폼의 로컬 개발 의존성, staging/e2e AWS 인프라, CI/CD 설정을 관리한다.

## 구성

- local: PostgreSQL 16, Redis 7, Silo(MinIO 호환 S3), Mailpit
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
| Silo S3 API | `http://localhost:9000` | MinIO 호환 로컬 이미지 저장소 |
| Silo Console | `http://localhost:9001` | 로컬 오브젝트 저장소 관리 UI |
| Mailpit SMTP | `localhost:1025` | 로컬 메일 수신 |
| Mailpit UI | `http://localhost:8025` | 수신 메일 확인 |

종료는 `docker compose down`, 데이터까지 삭제하려면 `docker compose down -v`를 사용한다.

루트 Compose는 README의 표준 로컬 부트스트랩이며 CI가 구성을 검증하므로 모든 서비스 이미지를 검토된 버전과 멀티 아키텍처 manifest digest로 고정한다. 기존 MinIO Community 컨테이너는 [유지보수가 종료](https://github.com/minio/minio#readme)되어 S3 API, `MINIO_*` 설정, 라우트, 디스크 형식을 유지하는 [Silo 2026-08-06](https://github.com/pgsty/silo/releases/tag/RELEASE.2026-08-06T00-00-00Z)으로 교체했다. 기존 `minio-data`가 필요하면 최초 Silo 실행 전에 백업하고, 폐기 가능한 로컬 데이터라면 `docker compose down -v`로 새 볼륨에서 시작한다.

BE 로컬 환경은 `POSTGRES_HOST=localhost`, `POSTGRES_PORT=5432`, `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres`, `POSTGRES_DATABASE=dadamjang`을 사용한다. Mailpit은 `localhost:1025` SMTP로 연결한다.

## staging Terraform

```bash
cd terraform/staging
terraform init -backend=false
terraform fmt -recursive
terraform validate
```

로컬 plan은 GitHub `staging` Environment와 같은 보호 값을 환경 변수로 주입하고 원격 state를 선택한다.

```bash
terraform login app.terraform.io
export TF_VAR_acm_certificate_arn="arn:aws:acm:ap-northeast-2:123456789012:certificate/example"
export TF_VAR_api_hostname="api.staging.example.com"
terraform init -reconfigure -backend-config=backend.hcl
terraform plan -input=false
```

CI의 `terraform-apply.yml`은 이름을 유지하지만 plan만 실행하며 `terraform apply`를 실행하지 않는다. Apply 자동화는 아직 제공하지 않는다. 향후 apply는 동일한 저장 plan을 별도 보호 승인 뒤 소비하는 계약으로 구현하거나, 그 전까지는 plan 생성·검토·apply를 하나의 통제된 out-of-band 수동 절차에서 수행한다.

상태 파일은 Git에 저장하지 않는다. AWS S3를 사용하지 않기 위해 HCP Terraform 원격 backend를 사용한다. `TF_BACKEND_CONFIG` GitHub Environment secret에는 비자격증명 backend 설정만 HCL로 넣고, HCP 인증은 별도의 `HCP_TERRAFORM_TOKEN` Environment secret으로 제공한다.

```hcl
# 예: HCP Terraform remote backend 설정
hostname     = "app.terraform.io"
organization = "your-terraform-cloud-organization"

workspaces {
  name = "dadamjang-staging"
}
```

staging과 e2e root module은 빈 `remote` backend block을 선언한다. 각 HCP Terraform workspace는 사용 전에 **Execution Mode = Local**로 설정한다. `TF_BACKEND_CONFIG`와 로컬 `backend.hcl`에는 `hostname`, `organization`, `workspaces`만 넣으며 실행 모드는 HCP workspace 설정에서 관리한다. CI는 보호된 `HCP_TERRAFORM_TOKEN`을 `hashicorp/setup-terraform`의 `cli_config_credentials_token` 입력으로만 전달해 Terraform CLI credentials를 구성한다. 로컬에서는 `terraform login app.terraform.io`로 동일한 credentials를 별도로 구성한다. 토큰은 `TF_BACKEND_CONFIG`, `backend.hcl`, Terraform plan, 업로드 artifact에 넣지 않는다. CI와 로컬 plan은 이 partial 설정으로 원격 state를 선택하고 GitHub runner 또는 로컬 Terraform에서 실행한다. `terraform init -backend=false`는 fmt/validate/test 같은 state 불필요 검사에만 사용한다.

첫 Terraform apply는 ECS service를 `desired_count = 0`으로 만든다. 아직 ECR 이미지가 없어서다. 이후 `api-deploy.yml`이 첫 이미지를 push하고 service를 1개 task로 시작한다. Terraform은 CI가 관리하는 task definition과 desired count를 덮어쓰지 않는다.

ALB health check는 인증 없이 정확히 `200`을 반환하는 backend readiness endpoint `/health/ready`를 사용한다. rollout 전에 배포 대상 backend commit이 이 endpoint를 제공하는지 확인한다.

ECS task는 RDS 연결에 `POSTGRES_SSL=true`와 `POSTGRES_SSL_CA_PATH=/etc/ssl/certs/aws-rds-global-bundle.pem`을 사용한다. backend image build는 AWS RDS global bundle을 고정 SHA-256으로 검증해 해당 경로에 넣는다. 현재 공식 URL은 `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`, 새로 검증한 SHA-256은 `e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3`이다. Download에는 Node 내장 `fetch`를 사용하며 build 중 mutable Alpine package를 설치하지 않는다.

상류 AWS bundle이 교체되면 digest도 바뀌므로 image build는 의도적으로 즉시 실패(fail closed)한다. Pin을 안전하게 갱신하려면 위 공식 URL에서만 bundle을 내려받고, `sha256sum`으로 새 SHA-256을 독립적으로 계산한 뒤 AWS가 공개한 인증서 출처 및 인증서 내용과 대조한다. Bundle과 digest 변경을 검토한 후에만 `docker/backend.Dockerfile`의 pin을 갱신한다.

### staging RDS safe destroy

staging RDS는 기본적으로 `enable_deletion_protection=true`, `skip_final_snapshot=false`다. 삭제가 필요하면 먼저 deletion protection만 `false`로 apply하고, final snapshot을 남긴 채 destroy한다. `final_snapshot_identifier`를 지정하지 않으면 `dadamjang-staging-postgres-final`을 사용한다.

같은 identifier의 snapshot이 이미 있으면 destroy가 실패한다. 보관할 snapshot에는 고유한 `final_snapshot_identifier` override를 지정한다. 기존 snapshot이 불필요함을 확인한 경우에만 다음 명령으로 수동 삭제한 뒤 다시 destroy한다.

```bash
aws rds delete-db-snapshot --db-snapshot-identifier dadamjang-staging-postgres-final
```

final snapshot을 명시적으로 포기하는 경우에만 `skip_final_snapshot=true`를 사용한다. e2e RDS는 테스트용 disposable 환경이라 deletion protection 없이 final snapshot을 건너뛴다.

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
| `ACM_CERTIFICATE_ARN` | Variable | staging HTTPS listener 인증서 ARN |
| `API_HOSTNAME` | Variable | staging API DNS hostname |
| `AWS_API_DEPLOY_ROLE_ARN` | Secret | `github_api_deploy_role_arn` |
| `AWS_TERRAFORM_ROLE_ARN` | Secret | staging Terraform 권한을 가진 별도 OIDC role ARN |
| `TF_BACKEND_CONFIG` | Secret | 원격 Terraform state backend HCL |
| `HCP_TERRAFORM_TOKEN` | Secret | Terraform CLI에서만 사용하는 HCP Terraform API token |

API deploy role은 ECR image 확인/업로드, ECS task definition 등록, migration task 실행, service 갱신에 필요한 권한만 허용한다. Terraform role은 별도로 만들고 AWS resource provisioning에 필요한 최소 권한만 부여한다. `staging` Environment는 배포 branch를 `main`으로만 제한하고 Required reviewers와 Prevent self-review를 설정해 배포자가 자신의 배포를 승인할 수 없게 한다. Terraform apply와 API deploy는 이 보호 규칙을 설정한 뒤 사용한다.

CloudWatch alarm 알림을 사용하려면 먼저 SNS topic과 subscription을 별도로 만들고 SNS topic ARN을 Terraform의 `alarm_action_arns`에 전달한다. 기본값은 빈 set이며 이 root는 SNS resource를 만들지 않는다.

현재 `staging` Environment variables는 아래 기본 naming으로 등록되어 있다.

```txt
AWS_REGION=ap-northeast-2
AWS_ECR_REPOSITORY=dadamjang-staging-api
AWS_ECS_CLUSTER=dadamjang-staging-cluster
AWS_ECS_SERVICE=dadamjang-staging-api
ACM_CERTIFICATE_ARN=arn:aws:acm:ap-northeast-2:123456789012:certificate/example
API_HOSTNAME=api.staging.example.com
```

아래 secrets는 실제 AWS 계정과 원격 Terraform backend 값이 있어야 등록할 수 있다.

```txt
AWS_API_DEPLOY_ROLE_ARN
AWS_TERRAFORM_ROLE_ARN
TF_BACKEND_CONFIG
HCP_TERRAFORM_TOKEN
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
  "CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL": "https://images.example.com/cdn-cgi/image",
  "SENTRY_DSN": "https://<public-key>@<sentry-host>/<project-id>"
}
```

새 task definition을 등록하기 전에 위 JSON의 모든 key를 실제 값으로 새 secret version에 등록해야 한다. Terraform은 JSON 값이 아니라 key별 ECS 참조만 추가하므로, 누락된 key가 있으면 새 task가 시작되지 않는다. OIDC trust 변경을 먼저 Terraform apply한 뒤 API deploy를 실행한다.

rollout 전에는 다음 조건을 모두 충족한다.

- 배포 대상 backend가 `/health/ready`에서 인증 없이 `200`을 반환한다.
- staging과 e2e Secrets Manager JSON에 `SENTRY_DSN`을 포함한 `local.runtime_secret_keys`의 exact key set과 실제 값을 등록한다.
- 새 task environment, secret reference, alarm 설정을 Terraform apply한 뒤 immutable image deploy를 실행한다.
- alarm 알림을 켤 경우 `alarm_action_arns`가 가리키는 SNS topic ARN과 subscription을 미리 만든다.

예시 JSON을 실제 값으로 저장한 뒤 다음처럼 등록한다.

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform -chdir=terraform/staging output -raw api_runtime_secret_arn)" \
  --secret-string file://runtime-secrets.json
```

Cloudflare에서는 R2 bucket, S3 API token(해당 bucket read/write만), public delivery base URL, Cloudflare Images transform base URL을 만든다. Cloudflare access key, secret key, account endpoint는 GitHub secret이 아니라 위 AWS Secrets Manager JSON에만 저장한다.

## GitHub Actions

- `infra-ci.yml`: infra PR/main 변경 시 Compose config, Terraform fmt, Terraform validate를 수행한다. state backend 없이 validate한다.
- `terraform-apply.yml`: 수동 실행만 가능하다. `staging` Environment 승인 후 보호된 입력과 원격 state로 plan만 실행한다.
- `api-deploy.yml`: `repository_dispatch` 타입 `backend-main` 또는 수동 실행으로 BE를 lint/test/build하고 ECR push, ECS deploy를 수행한다. deploy job은 `staging` Environment 승인을 요구한다.

API deploy는 test job이 확정한 backend commit만 다시 checkout한다. Image tag `backend-<backend-sha>-dockerfile-<dockerfile-blob-sha>`는 테스트한 backend source와 infra가 소유한 Docker build definition을 함께 식별하며, 같은 tag가 ECR에 있으면 기존 immutable image를 재사용한다. Node base는 공식 `linux/amd64` manifest digest로 고정하고 build와 Fargate runtime도 각각 `linux/amd64`, `X86_64`로 고정한다. Push 또는 tag 재사용 후 ECR에서 digest를 다시 조회해 `repository@sha256:...`만 task definition에 등록한다.

배포는 ECR digest를 확정한 뒤 해당 image 안의 `/app/retired-migrations/0005_catalog_demo_products.sql`을 실행 환경에서 직접 읽어 historical SHA-256 `44d98c294ac8c2afa502f7bdb2c65411df7d4879dad39cd5b4fbc8cf9c94059f`와 일치하는지 확인한다. 검증되지 않은 digest는 task definition에 전달하지 않는다.

`ecs_release_contract`는 Terraform이 만든 canonical task definition, apply 시점에 refresh한 ECS service의 exact task-definition revision, ECR repository, runtime secret 이름, task-contract source hash를 하나로 묶는다. API deploy는 live service의 exact revision을 읽고 canonical contract를 엄격히 검증한 다음 canonical definition에서 새 digest와 `SENTRY_RELEASE`만 바꿔 등록한다. Live contract가 canonical과 이미 같으면 일반 image-only deploy로 진행한다. Contract가 다르면 live revision이 Terraform apply가 관측한 revision과 정확히 같을 때만 한 번의 contract transition을 허용한다. 따라서 service drift나 다른 infra commit의 stale state는 자동 승인되지 않는다.

기존 staging에 이 output 또는 새 runtime contract를 처음 적용할 때는 secrets를 먼저 준비하고, 통제된 out-of-band 절차에서 같은 infra commit으로 staging Terraform plan을 생성·검토한 뒤 그 저장 plan을 수동 apply한다. 이 apply는 `ignore_changes = [task_definition]` 때문에 mutable/placeholder image로 service를 재배포하지 않고 새 canonical revision과 현재 service revision을 state에 기록한다. 그 다음 같은 commit의 API deploy를 실행하면 immutable digest를 사용해 canonical contract로 전환한다. 이후 image-only deploy는 별도 Terraform apply가 필요 없으며, 미래 runtime contract 변경에는 같은 plan 검토와 수동 apply → API deploy 순서를 반복한다. Apply 이후 live revision이 예상과 다르면 drift를 조사·복구한 뒤 새 plan을 검토해야 하며 state만 다시 승인해서는 안 된다.

`dadamjang-be`의 main merge가 deploy를 자동 시작하려면 BE workflow가 infra repository에 dispatch를 보내야 한다. infra workflow만으로는 다른 repository의 main push를 구독할 수 없다.

`repository_dispatch`의 `client_payload.ref`는 누락이나 mutable fallback 없이 정확한 소문자 40자리 commit SHA여야 한다. 수동 `workflow_dispatch`는 별도의 필수 `backend_ref` 문자열을 사용하며 기본값은 `main`이다.

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
