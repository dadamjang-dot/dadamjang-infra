locals {
  database_name = "dadamjang_e2e"
  name_prefix   = "${var.project_name}-e2e"

  common_tags = {
    Environment = "e2e"
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }

  runtime_secret_keys = toset([
    "CLIENT_URL",
    "CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL",
    "CLOUDFLARE_R2_ACCESS_KEY_ID",
    "CLOUDFLARE_R2_BUCKET",
    "CLOUDFLARE_R2_ENDPOINT",
    "CLOUDFLARE_R2_PUBLIC_BASE_URL",
    "CLOUDFLARE_R2_SECRET_ACCESS_KEY",
    "EMAIL_CODE_PEPPER",
    "JWT_ACCESS_TOKEN_EXP",
    "JWT_ACCESS_TOKEN_SECRET",
    "JWT_REFRESH_TOKEN_EXP",
    "JWT_REFRESH_TOKEN_SECRET",
    "KAKAO_CALLBACK_URL",
    "KAKAO_CLIENT_ID",
    "RESEND_API_KEY",
    "RESEND_FROM_EMAIL",
  ])
}
