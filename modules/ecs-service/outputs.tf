output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.main.name
}

output "service_arn" {
  description = "ECS service ARN"
  value       = aws_ecs_service.main.id
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.service.arn
}

output "task_security_group_id" {
  description = "Task security group ID"
  value       = aws_security_group.task.id
}

output "execution_role_arn" {
  description = "Task execution role ARN"
  value       = aws_iam_role.execution.arn
}
