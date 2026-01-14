variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
  default     = "production-cluster"
}

variable "instance_type" {
  description = "EC2 instance type for ECS"
  type        = string
  default     = "t3.medium"
}

variable "asg_min_size" {
  description = "Minimum ASG size"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum ASG size"
  type        = number
  default     = 10
}

variable "asg_desired_capacity" {
  description = "Desired ASG capacity"
  type        = number
  default     = 2
}

variable "on_demand_base_capacity" {
  description = "Absolute minimum On-Demand instances (fail resilience)"
  type        = number
  default     = 1
}

variable "on_demand_percentage_above_base" {
  description = "% of on demand above base (20% = 1 OD + 4 Spot for 5 total)"
  type        = number
  default     = 20
}

variable "services" {
  description = "Secrets Manager vault"
  type = map(object({
    desired_count  = number
    path_pattern   = list(string)
    priority       = number
    container_port = number
    cpu            = number
    memory         = number
  }))
  
  default = {
    nginx = {
      desired_count  = 2
      path_pattern   = ["/nginx*"]
      priority       = 100
      container_port = 80
      cpu            = 256
      memory         = 512
    }
    api = {
      desired_count  = 2
      path_pattern   = ["/api*"]
      priority       = 110
      container_port = 80
      cpu            = 256
      memory         = 512
    }
  }
}

variable "service_cpu_target" {
  description = "CPU utilization for service scaling"
  type        = number
  default     = 70
}

variable "service_memory_target" {
  description = "memory utilization for service scaling"
  type        = number
  default     = 80
}

variable "alb_requests_per_target" {
  description = "requests per task for ALB-based scaling"
  type        = number
  default     = 1000
}
