variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet id for ECS instances"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "asg_min_size" {
  description = "Minimum ASG size"
  type        = number
}

variable "asg_max_size" {
  description = "Maximum ASG size"
  type        = number
}

variable "asg_desired_capacity" {
  description = "Desired ASG capacity"
  type        = number
}

variable "on_demand_base_capacity" {
  description = "minimum On-Demand instances"
  type        = number
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of on demand above base  (20%)"
  type        = number
}
