variable "alb_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the public staging ALB."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}

variable "acm_certificate_arn" {
  description = "Issued ACM certificate ARN for the public staging API hostname."
  type        = string
}

variable "api_container_cpu" {
  description = "Fargate CPU units allocated to the API task."
  type        = number
  default     = 256
}

variable "api_hostname" {
  description = "Public DNS hostname covered by acm_certificate_arn and routed to the staging ALB."
  type        = string
}

variable "api_container_memory" {
  description = "Fargate memory in MiB allocated to the API task."
  type        = number
  default     = 512
}

variable "api_image_tag" {
  description = "Immutable ECR image tag deployed by the ECS service."
  type        = string
  default     = "bootstrap"
}

variable "aws_region" {
  description = "AWS region for the staging environment."
  type        = string
  default     = "ap-northeast-2"
}

variable "database_instance_class" {
  description = "RDS instance class for staging PostgreSQL."
  type        = string
  default     = "db.t4g.micro"
}

variable "database_name" {
  description = "Initial PostgreSQL database name."
  type        = string
  default     = "dadamjang"
}

variable "database_username" {
  description = "Master username for the staging PostgreSQL database."
  type        = string
  default     = "dadamjang"
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for stateful staging resources."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub owner/repository allowed to assume the API deployment OIDC role."
  type        = string
  default     = "dadamjang-dot/dadamjang-infra"
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention period for the API service."
  type        = number
  default     = 30
}

variable "project_name" {
  description = "Project name used in AWS resource names and tags."
  type        = string
  default     = "dadamjang"
}

variable "vpc_cidr" {
  description = "CIDR block for the staging VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "environment" {
  description = "Deployment environment. This root module supports staging only."
  type        = string
  default     = "staging"

  validation {
    condition     = var.environment == "staging"
    error_message = "Only the staging environment is supported by this Terraform root module."
  }
}
