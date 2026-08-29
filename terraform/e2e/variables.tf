variable "acm_certificate_arn" {
  description = "Issued ACM certificate ARN for the public e2e API hostname."
  type        = string
}

variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the public e2e ALB."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}

variable "api_container_cpu" {
  description = "Fargate CPU units allocated to the e2e API task."
  type        = number
  default     = 256
}

variable "api_container_memory" {
  description = "Fargate memory in MiB allocated to the e2e API task."
  type        = number
  default     = 512
}

variable "api_hostname" {
  description = "Public DNS hostname covered by acm_certificate_arn and routed to the e2e ALB."
  type        = string
}

variable "api_image_tag" {
  description = "Immutable ECR image tag used by the e2e ECS task definition."
  type        = string
  default     = "bootstrap"
}

variable "aws_region" {
  description = "AWS region for the e2e environment."
  type        = string
  default     = "ap-northeast-2"
}

variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the isolated e2e R2 buckets."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a lowercase 32-character Cloudflare account ID."
  }
}

variable "cloudflare_r2_final_bucket_name" {
  description = "Existing e2e R2 bucket containing promoted final images."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", var.cloudflare_r2_final_bucket_name))
    error_message = "cloudflare_r2_final_bucket_name must be a valid lowercase R2 bucket name."
  }
}

variable "database_instance_class" {
  description = "RDS instance class for e2e PostgreSQL."
  type        = string
  default     = "db.t4g.micro"
}

variable "database_username" {
  description = "Master username for the e2e PostgreSQL database."
  type        = string
  default     = "dadamjang"
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention period for e2e API tasks."
  type        = number
  default     = 7
}

variable "mobile_github_repository" {
  description = "GitHub owner/repository containing the trusted mobile e2e workflow."
  type        = string
  default     = "dadamjang-dot/dadamjang-fe"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.mobile_github_repository))
    error_message = "mobile_github_repository must use owner/repository format."
  }
}

variable "mobile_github_environment" {
  description = "Protected GitHub Environment required by the mobile e2e workflow."
  type        = string
  default     = "mobile-e2e"
}

variable "project_name" {
  description = "Project name used in AWS resource names and tags."
  type        = string
  default     = "dadamjang"
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated e2e VPC."
  type        = string
  default     = "10.50.0.0/16"
}
