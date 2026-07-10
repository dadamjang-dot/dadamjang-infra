# 다담장 Infrastructure

다담장 플랫폼의 로컬 개발 환경, 배포 설정, 관측 구성을 관리합니다.

## 범위

- Docker Compose 기반 로컬 환경
- PostgreSQL·API·관측 도구 구성
- Terraform 기반 인프라 선언
- GitHub Actions와 EAS build/deployment 설정

## 배포 원칙

- 구매자 앱은 EAS development, preview, production profile을 분리합니다.
- iOS는 TestFlight를 거쳐 App Store 제출을 진행합니다.
- Android는 internal track부터 검증합니다.
- 실제 배포·제출은 별도 승인 후 실행합니다.
Dadamjang infrastructure, local development, and deployment configuration
