output "api_alb_dns_name" {
  description = "ALB DNS name to target from the e2e API hostname DNS record."
  value       = aws_lb.api.dns_name
}

output "api_ecr_repository_url" {
  description = "ECR repository URL for immutable e2e API images."
  value       = aws_ecr_repository.api.repository_url
}

output "e2e_api_url" {
  description = "E2E_API_URL for the mobile workflow."
  value       = "https://${var.api_hostname}/graphql"
}

output "e2e_aws_region" {
  description = "E2E_AWS_REGION for the protected mobile e2e workflow."
  value       = var.aws_region
}

output "e2e_aws_role_arn" {
  description = "E2E_AWS_ROLE_ARN for the protected mobile e2e workflow."
  value       = aws_iam_role.mobile_e2e.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster containing the isolated e2e API."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service scaled to one during e2e and zero during cleanup."
  value       = aws_ecs_service.api.name
}

output "ecs_task_definition_arn" {
  description = "Task definition used for the API service and one-off e2e reset task."
  value       = aws_ecs_task_definition.api.arn
}

output "ecs_task_family" {
  description = "Task definition family used by CI to resolve the active e2e revision."
  value       = aws_ecs_task_definition.api.family
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the one-off e2e reset task."
  value       = values(aws_subnet.private)[*].id
}

output "private_subnet_ids_csv" {
  description = "AWS_PRIVATE_SUBNET_IDS comma-separated value for the mobile workflow."
  value       = join(",", values(aws_subnet.private)[*].id)
}

output "api_security_group_id" {
  description = "Security group ID for the one-off e2e reset task."
  value       = aws_security_group.api.id
}
