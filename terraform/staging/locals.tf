locals {
  name_prefix            = "${var.project_name}-${var.environment}"
  pending_r2_bucket_name = "${local.name_prefix}-pending"

  r2_application_bucket_names = toset([
    var.cloudflare_r2_final_bucket_name,
    local.pending_r2_bucket_name,
  ])

  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.project_name
  }

  runtime_secret_keys = toset([
    "API_PUBLIC_BASE_URL",
    "CLOUDFLARE_R2_ACCESS_KEY_ID",
    "CLOUDFLARE_R2_BUCKET",
    "CLOUDFLARE_R2_ENDPOINT",
    "CLOUDFLARE_R2_PENDING_BUCKET",
    "CLOUDFLARE_R2_PUBLIC_BASE_URL",
    "CLOUDFLARE_R2_SECRET_ACCESS_KEY",
    "CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL",
    "DADAMJANG_BO_URL",
    "EMAIL_CODE_PEPPER",
    "IDENTITY_CI_PEPPER",
    "IDENTITY_INICIS_API_KEY",
    "IDENTITY_INICIS_CALLBACK_BASE_URL",
    "IDENTITY_INICIS_MID",
    "IDENTITY_INICIS_SEED_IV",
    "JWT_ACCESS_TOKEN_SECRET",
    "JWT_ACCESS_TOKEN_EXP",
    "JWT_REFRESH_TOKEN_SECRET",
    "JWT_REFRESH_TOKEN_EXP",
    "KAKAO_CLIENT_ID",
    "KAKAO_CALLBACK_URL",
    "CLIENT_URL",
    "RESEND_API_KEY",
    "RESEND_FROM_EMAIL",
    "SENTRY_DSN",
  ])
}
