**What this is**

A simple overview of how the Terraform project builds an ECS-on-EC2 stack: ALB in public subnets, ECS tasks in private subnets, ASG with mixed On‑Demand/Spot, and per-service secrets.

**High level (TL;DR)**

Internet -> ALB (public subnets) -> path routing -> ECS tasks (private subnets)

ECS runs on EC2 instances (no public IPs) in an ASG configured with a mixed instances policy (On‑Demand base + Spot overflow).

ECS Capacity Provider is attached to the ASG and manages cluster scaling.

Each service gets a target group + listener rule on the ALB and a per-service secrets vault (Secrets Manager in this implementation).

CloudWatch + Container Insights for monitoring, EventBridge rule for Spot interruption warnings.

**ASCII diagram**

For this we have a set of files that show the complete ARCHITECTURE 
- Architecture-Overview.drawio
- Architecture-Overview.drawio.png
                                            
ECS Cluster:
  ASG (mixed On-Demand + Spot) -> EC2 instances -> ECS agent -> runs tasks
Secrets:
  Per-service Secrets Manager vault -> task execution role reads secret -> injected as env vars
Important components and notes (short, practical)

VPC & subnets: 2 AZs, 2 public + 2 private. Public subnets host ALB and NAT gateway. Private subnets host EC2 instances running ECS tasks.

ALB: internet-facing, path-based rules (/nginx*, /api*). Health checks hit / by default and expect a 200 response.

ECS Cluster: EC2 launch type, Container Insights enabled.

ASG + Capacity Provider: ASG uses mixed instances policy; capacity provider has managed scaling, termination protection enabled. On‑Demand base + Spot overflow (20%/80% default).

Services: each service module creates a task definition, service, target group, listener rule, autoscaling policies (CPU, memory, ALB request count).

Secrets: current implementation uses Secrets Manager per service and initializes a PORT value.

Security: tasks/instances are in private subnets, task SG allows only ALB SG -> container port. Execution role has minimum permissions plus access to the service secret ARN.

Observability: CloudWatch log groups per service, Container Insights enabled, EventBridge spot interruption rule (so tasks can drain on a warning).

**Why this layout?**

ALB as single public entry point keeps attack surface small and simplifies TLS (terminate at ALB).

Mixed ASG saves cost with Spot while On‑Demand base keeps some capacity stable during spot interruptions.

Capacity Provider + managed scaling avoids manual ASG logic and ties cluster scaling to task demand.

Quick checklist for changes people usually make
