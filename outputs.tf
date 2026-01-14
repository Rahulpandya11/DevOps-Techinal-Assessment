output "alb_dns_name" {
  description = "DNS name of ALB"
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "ALB URL"
  value       = "http://${module.alb.alb_dns_name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "ecs_cluster_name" {
  description = "ecs cluster name"
  value       = module.ecs_cluster.cluster_name
}

output "ecs_cluster_arn" {
  description = "ecs cluster arn"
  value       = module.ecs_cluster.cluster_arn
}

output "service_endpoints" {
  description = "Service access paths"
  value = {
    for name, config in var.services :
    name => {
      url          = "http://${module.alb.alb_dns_name}${config.path_pattern[0]}"
      path_pattern = config.path_pattern
    }
  }
}

output "capacity_provider_name" {
  description = "ECS capacity provider name"
  value       = module.ecs_cluster.capacity_provider_name
}

output "asg_name" {
  description = "ASG name"
  value       = module.ecs_cluster.asg_name
}

output "secrets_configuration" {
  description = "Secrets Manager"
  value = {
    services = keys(var.services)
    note     = "Each service has its own Secrets Manager vault named after the service"
  }
}
