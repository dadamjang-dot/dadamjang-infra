output "api_ecr_repository_url" {
  description = "ECR repository URL for the staging API image."
  value       = aws_ecr_repository.api.repository_url
}

output "api_runtime_secret_arn" {
  description = "Secrets Manager ARN that must contain the API runtime secret JSON."
  value       = aws_secretsmanager_secret.api_runtime.arn
}

output "api_url" {
  description = "Public HTTPS endpoint for the staging API."
  value       = "https://${var.api_hostname}"
}

output "api_alb_dns_name" {
  description = "ALB DNS name to target from the staging API hostname DNS record."
  value       = aws_lb.api.dns_name
}

output "database_master_secret_arn" {
  description = "RDS-managed master credential secret ARN."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
  sensitive   = true
}

output "ecs_cluster_name" {
  description = "ECS cluster name for the staging API service."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name for the staging API."
  value       = aws_ecs_service.api.name
}

output "ecs_task_definition_arn" {
  description = "Terraform-reviewed ECS task definition ARN used to validate release configuration."
  value       = aws_ecs_task_definition.api.arn
}

output "ecs_task_family" {
  description = "ECS task definition family for staging API tasks."
  value       = aws_ecs_task_definition.api.family
}

output "ecs_release_contract" {
  description = "Reviewed target and exact service revision observed by the latest Terraform apply."
  value = {
    canonical_task_definition_arn        = aws_ecs_task_definition.api.arn
    image_repository                     = aws_ecr_repository.api.repository_url
    observed_service_task_definition_arn = aws_ecs_service.api.task_definition
    runtime_secret_names                 = sort(concat(["POSTGRES_PASSWORD"], tolist(local.runtime_secret_keys)))
    source_hashes = {
      "application.tf" = filesha256("${path.module}/application.tf")
      "locals.tf"      = filesha256("${path.module}/locals.tf")
      "outputs.tf"     = filesha256("${path.module}/outputs.tf")
      "variables.tf"   = filesha256("${path.module}/variables.tf")
    }
    task_family = aws_ecs_task_definition.api.family
  }
}

output "github_api_deploy_role_arn" {
  description = "OIDC role ARN for the GitHub workflow that pushes and deploys the API."
  value       = aws_iam_role.github_api_deploy.arn
}
