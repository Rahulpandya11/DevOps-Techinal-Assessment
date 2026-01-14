variable "service_name" {
  description = "Service name"
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ID"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "capacity_provider_name" {
  description = "ECS capacity provider name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for tasks"
  type        = list(string)
}

variable "alb_listener_arn" {
  description = "ALB listener ARN"
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB security group ID"
  type        = string
}

variable "desired_count" {
  description = "Desired task count"
  type        = number
}

variable "path_pattern" {
  description = "ALB path patterns"
  type        = list(string)
}

variable "listener_priority" {
  description = "ALB listener rule priority"
  type        = number
}

variable "container_port" {
  description = "Container port"
  type        = number
}

variable "cpu" {
  description = "Task CPU units"
  type        = number
}

variable "memory" {
  description = "Task memory (MiB)"
  type        = number
}

variable "cpu_target_value" {
  description = "Target CPU utilization for auto-scaling"
  type        = number
}

variable "memory_target_value" {
  description = "Target memory utilization for auto-scaling"
  type        = number
}

variable "alb_requests_per_target" {
  description = "Target requests per task for auto-scaling"
  type        = number
}

variable "region" {
  description = "AWS region"
  type        = string
}
