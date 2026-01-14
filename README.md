# Production-Grade ECS on EC2 Infrastructure

## Overview

This Terraform project implements a production-grade AWS ECS infrastructure using EC2 launch type with:
- Zero-downtime deployments
- Secure secrets management via AWS Secrets Manager
- Cost-optimized capacity using On-Demand + Spot instances
- Multi-AZ high availability
- Auto-scaling at both service and cluster levels

## Architecture Highlights

- **ECS Cluster**: EC2-based with Container Insights enabled
- **Capacity Strategy**: 20% On-Demand baseline + 80% Spot for scale
- **Networking**: Private subnets for ECS, public subnets for ALB
- **Load Balancing**: Shared Application Load Balancer with path-based routing
- **Secrets**: AWS Secrets Manager per-service vaults (no secrets in code/state)
- **Scaling**: Multi-dimensional auto-scaling (CPU, Memory, ALB requests)

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with appropriate credentials
- AWS account with permissions to create VPC, ECS, ALB, IAM, Secrets Manager resources

## Project Structure

```
.
├── main.tf                      # Root module orchestration
├── variables.tf                 # Input variables
├── outputs.tf                   # Output values
├── modules/
│   ├── networking/              # VPC, subnets, NAT Gateway
│   ├── alb/                     # Application Load Balancer
│   ├── ecs-cluster/             # ECS cluster, ASG, capacity provider
│   └── ecs-service/             # ECS service (deployed per service)
├── ARCHITECTURE.md              # Detailed architecture documentation
├── DESIGN.md                    # Design decisions and tradeoffs
├── DEPLOYMENT-GUIDE.md          # Step-by-step deployment guide
├── ADDENDUM.md                  # Production stress test scenarios
├── README.md                  # complete project overview
├── Architecture-Overview.drawio          # draw.io Architecture Diagram
└── Architecture-Overview.drawio.png                  # Architecture Diagram in image format
```

## Quick Start

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Review Configuration

```hcl
region      = "us-east-1"
environment = "production"
vpc_cidr    = "10.0.0.0/16"

cluster_name         = "production-cluster"
instance_type        = "t3.medium"
asg_min_size         = 2
asg_max_size         = 10
asg_desired_capacity = 2

# Cost optimization: 1 On-Demand + 80% Spot above base
on_demand_base_capacity         = 1
on_demand_percentage_above_base = 20

services = {
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
```

### 3. Plan Deployment

```bash
terraform plan
```

### 4. Deploy Infrastructure

```bash
terraform apply
```

### 5. Access Services

After deployment, Terraform outputs will provide:

```bash
# Get ALB URL
terraform output alb_url

# Get service endpoints
terraform output service_endpoints
```

## Secrets Management

Each service automatically gets its own Secrets Manager vault named after the service (e.g., "nginx", "api").

### Initial Setup

The vault is created with a PORT variable. To add more secrets: use AWS CLI or GUI inside AWS in Secret Manager

### How It Works

- Secrets are pulled at container startup via ECS task execution role
- Only the specific service's execution role can access its own vault
- No secrets appear in Terraform state or code
- `lifecycle.ignore_changes` prevents Terraform from overwriting manual updates

## Key Features

### Zero-Downtime Deployments

- **Deployment Settings**: 200% max, 100% min healthy
- **Circuit Breaker**: Automatic rollback on failed deployments
- **ALB Health Checks**: 30s interval, 2 healthy/unhealthy thresholds
- **Deregistration Delay**: 30s for graceful connection draining

### Cost Optimization

- **On-Demand Base**: 1 instance (always running for stability)
- **Spot Instances**: 80% of additional capacity
- **Multiple Instance Types**: t3.medium, t3a.medium, t2.medium for Spot diversity
- **Price-Capacity Optimized**: Balances cost and availability

### High Availability

- **Multi-AZ**: Resources spread across 2 availability zones
- **Spot Interruption Handling**: ECS draining enabled, EventBridge monitoring
- **Capacity Provider Scaling**: Automatic cluster scaling based on task demand
- **Service Auto-Scaling**: CPU, memory, and request-based scaling

### Security

- **Private Subnets**: ECS instances and tasks run in private subnets
- **No Public IPs**: Tasks and instances have no direct internet exposure
- **NAT Gateway**: Outbound internet access via NAT
- **Security Groups**: Least-privilege access (ALB → Tasks only)
- **IAM Roles**: Task execution roles with minimal permissions per service
- **Secrets Manager**: Encrypted secrets with automatic rotation support

## Auto-Scaling Configuration

### Service-Level Scaling
- **CPU Target**: 70% utilization
- **Memory Target**: 80% utilization
- **ALB Requests**: 1000 requests/target
- **Scale Out**: 60s cooldown
- **Scale In**: 300s cooldown (5 min)

### Cluster-Level Scaling
- **Target Capacity**: 100%
- **Minimum Step**: 1 instance
- **Maximum Step**: 10 instances
- **Warmup Period**: 300s (5 min)

## Monitoring and Observability

- **Container Insights**: Enabled on ECS cluster
- **CloudWatch Logs**: Per-service log groups with 14-day retention
- **Spot Interruption Warnings**: EventBridge rule captures EC2 Spot interruptions
- **Detailed Monitoring**: Enabled on EC2 instances

## Time Spent (Estimated but it's more than what shows here)

- Initial setup and research: 30-50 minutes
- Core infrastructure implementation: 90-120 minutes
- Secrets management integration: 45-60 minutes
- Documentation and testing: 45-60 minutes
- **Total**: ~3.5-5 hours

## Shortcuts Taken

1. **Single NAT Gateway**: Production should use NAT per AZ for HA
2. **No HTTPS/TLS**: Should add ACM certificate and HTTPS listener
3. **No WAF**: Production should include AWS WAF for ALB
4. **No VPC Endpoints**: Could add for AWS services (ECR, Secrets Manager, CloudWatch)
5. **Limited Monitoring**: Production needs comprehensive CloudWatch alarms and dashboards
6. **No Backup Strategy**: Should implement automated snapshots and DR procedures

## AI/Tools Used

- **OPEN AI**: Used for AWS service documentation, and debugging
- **Terraform Documentation**: Referenced for resource arguments and behaviors
- **AWS Documentation**: Consulted for ECS, ALB, and Secrets Manager integration patterns

## What Would Be Done Next

1. **Enhanced Monitoring**: CloudWatch dashboards, SNS alarms for critical metrics
2. **Cost Analysis**: Cost and usage reports, budget alerts
3. **Security Hardening**: VPC endpoints, IMDSv2 enforcement, secrets rotation
4. **TLS Termination**: ACM certificate, HTTPS listener, HTTP→HTTPS redirect
5. **CI/CD Pipeline**: Automated deployments with GitHub Actions/GitLab CI
6. **Disaster Recovery**: Multi-region failover, backup automation
7. **Compliance**: AWS Config rules, security scanning, audit logging
8. **Performance Testing**: Load testing with realistic traffic patterns
9. **Documentation**: Runbooks for common operations and incident response
10. **Capacity Planning**: Right-sizing analysis, reserved instance optimization

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning**: This will delete all resources including data. Ensure you have backups if needed.
