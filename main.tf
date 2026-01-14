
terraform {
  required_version = ">= 1.5"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "networking" {
  source = "./modules/networking"
  
  vpc_cidr    = var.vpc_cidr
  environment = var.environment
}

module "alb" {
  source = "./modules/alb"
  
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  environment       = var.environment
}

module "ecs_cluster" {
  source = "./modules/ecs-cluster"
  
  cluster_name                     = var.cluster_name
  vpc_id                           = module.networking.vpc_id
  private_subnet_ids               = module.networking.private_subnet_ids
  instance_type                    = var.instance_type
  asg_min_size                     = var.asg_min_size
  asg_max_size                     = var.asg_max_size
  asg_desired_capacity             = var.asg_desired_capacity
  on_demand_base_capacity          = var.on_demand_base_capacity
  on_demand_percentage_above_base  = var.on_demand_percentage_above_base
}

module "services" {
  source   = "./modules/ecs-service"
  for_each = var.services
  
  service_name            = each.key
  cluster_id              = module.ecs_cluster.cluster_id
  cluster_name            = module.ecs_cluster.cluster_name
  capacity_provider_name  = module.ecs_cluster.capacity_provider_name
  vpc_id                  = module.networking.vpc_id
  private_subnet_ids      = module.networking.private_subnet_ids
  alb_listener_arn        = module.alb.listener_arn
  alb_security_group_id   = module.alb.security_group_id
  
  desired_count           = each.value.desired_count
  path_pattern            = each.value.path_pattern
  listener_priority       = each.value.priority
  container_port          = each.value.container_port
  cpu                     = each.value.cpu
  memory                  = each.value.memory
  
  
  cpu_target_value        = var.service_cpu_target
  memory_target_value     = var.service_memory_target
  alb_requests_per_target = var.alb_requests_per_target
  
  region                  = var.region
}
