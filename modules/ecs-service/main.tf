
resource "aws_secretsmanager_secret" "service" {
  name        = var.service_name
  description = "Secrets vault for ${var.service_name} service - add any environment variables here"
  
  tags = {
    Service = var.service_name
    ManagedBy = "Terraform"
  }
}

resource "aws_secretsmanager_secret_version" "service" {
  secret_id = aws_secretsmanager_secret.service.id
  secret_string = jsonencode({
    PORT = tostring(var.container_port)
  })
  
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Security group for ECS tasks
resource "aws_security_group" "task" {
  name_prefix = "${var.service_name}-task-"
  description = "Security group for ${var.service_name} ECS tasks"
  vpc_id      = var.vpc_id
  
  ingress {
    description     = "Allow traffic from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }
  
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name    = "${var.service_name}-task-sg"
    Service = var.service_name
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# IAM role for task execution (pulls images, writes logs, reads secrets)
resource "aws_iam_role" "execution" {
  name = "${var.service_name}-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  
  tags = {
    Service = var.service_name
  }
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "secrets_access" {
  name = "${var.service_name}-secrets-access"
  role = aws_iam_role.execution.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.service.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = 14
  
  tags = {
    Service = var.service_name
  }
}

resource "aws_ecs_task_definition" "service" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  
  container_definitions = jsonencode([{
    name  = var.service_name
    image = "nginx:latest"
    
    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]
    
    
    secrets = [
      {
        name      = "SECRETS_VAULT"
        valueFrom = aws_secretsmanager_secret.service.arn
      }
    ]
    
    
    
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
    
    essential = true
  }])
  
  tags = {
    Service = var.service_name
  }
}


resource "aws_lb_target_group" "service" {
  name        = "${var.service_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  
  health_check {
    enabled             = true
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
  
  deregistration_delay = 30
  
  tags = {
    Service = var.service_name
  }
}


resource "aws_lb_listener_rule" "service" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority
  
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service.arn
  }
  
  condition {
    path_pattern {
      values = var.path_pattern
    }
  }
  
  tags = {
    Service = var.service_name
  }
}


resource "aws_ecs_service" "main" {
  name            = var.service_name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.service.arn
  desired_count   = var.desired_count
  
  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
    base              = 0
  }
  
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.service.arn
    container_name   = var.service_name
    container_port   = var.container_port
  }
  
  
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  
  wait_for_steady_state = true
  
  tags = {
    Service = var.service_name
  }
  
  lifecycle {
    ignore_changes = [desired_count]
  }
}


resource "aws_appautoscaling_target" "service" {
  max_capacity       = 20
  min_capacity       = var.desired_count
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  
  depends_on = [aws_ecs_service.main]
}


resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.service_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service.resource_id
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service.service_namespace
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_value
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}


resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.service_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service.resource_id
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service.service_namespace
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = var.memory_target_value
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}


resource "aws_appautoscaling_policy" "alb_requests" {
  name               = "${var.service_name}-alb-requests-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.service.resource_id
  scalable_dimension = aws_appautoscaling_target.service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.service.service_namespace
  
  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${regex("app/.*/[^/]+", var.alb_listener_arn)}/${aws_lb_target_group.service.arn_suffix}"
    }
    target_value       = var.alb_requests_per_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

