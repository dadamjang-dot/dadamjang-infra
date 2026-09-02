# E2E Terraform

Staging과 분리된 자동화 테스트 환경을 정의하는 Terraform root입니다.

## 구성

- 독립 VPC와 public ALB
- private subnet의 ECS Fargate API
- `dadamjang_e2e` RDS PostgreSQL과 ElastiCache
- ECR, Secrets Manager, CloudWatch Logs
- 비공개 Cloudflare R2 pending bucket
- GitHub Actions OIDC role

## 검증

```bash
terraform init -backend=false -input=false
terraform fmt -check -recursive
terraform validate
terraform test
```

## 출력

API URL, AWS region, OIDC role, ECS와 네트워크 식별자를 output으로 제공합니다. 런타임 secret 값과 데이터베이스 자격 증명은 output에 포함하지 않습니다.

현재 이 저장소에는 E2E apply workflow가 없으므로 root는 선언과 로컬 검증 용도로만 사용합니다.
