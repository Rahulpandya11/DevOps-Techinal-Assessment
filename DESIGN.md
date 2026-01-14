# DESIGN.md

## Production-Grade ECS Infrastructure Design

This document explains the key design decisions, tradeoffs, and implementation details for the zero-downtime, cost-optimized ECS infrastructure.

---

## A) Zero-Downtime Deployments (Currently i configured this in my current org)

### Deployment Settings (Basically rolling update strategy)

**ECS Service Configuration**:
```hcl
deployment_maximum_percent         = 200  # Can run 2x tasks during deploy
deployment_minimum_healthy_percent = 100  # Never drop below desired count (it's 100% not counts of task)
```

**How it works**:
1. Service has 2 tasks running (100% healthy)
2. Deployment starts: ECS launches 2 new tasks (200% = 4 tasks total)
3. New tasks register with ALB, pass health checks
4. ALB starts sending traffic to new tasks
5. Old tasks deregister from ALB (30s drain)
6. Old tasks terminate only after new tasks are healthy

**Result**: Zero dropped requests, users never notice deployment.

### ALB Health Check Configuration

```hcl
health_check {
  enabled             = true
  path                = "/"
  interval            = 30      # Check every 30 seconds
  timeout             = 5       # 5s response timeout
  healthy_threshold   = 2       # 2 consecutive successes = healthy
  unhealthy_threshold = 2       # 2 consecutive failures = unhealthy
  matcher             = "200"
}
```

**Why this works**:
- New tasks must pass 2 health checks (60s) before receiving traffic
- Old tasks drain for 30s after deregistration
- 200% deployment capacity allows full replacement without capacity loss

### Circuit Breaker

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

Automatically rolls back failed deployments, preventing bad code from taking down the service.

---

## B) Secrets Management

### Architecture: Secrets Manager → ECS Task

**Flow**:
```
AWS Secrets Manager Vault (per service)
         ↓
Task Execution Role (least privilege)
         ↓
ECS pulls secrets at container start
         ↓
Environment variables in container
```

### Why No Secrets in Terraform State

1. **Secret Creation**: Vault created with initial PORT value
2. **Lifecycle Management**: 
   ```hcl
   lifecycle {
     ignore_changes = [secret_string]
   }
   ```
   Terraform creates vault but doesn't manage secret content updates

3. **Manual Secret Updates**: Use AWS CLI or Console

4. **No State Pollution**: Secret values never written to Terraform state

### Which Role Reads Secrets

**Task Execution Role** (NOT task role):
- Executes during task startup (before container runs)
- Permissions:
  ```json
  {
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "arn:aws:secretsmanager:region:account:secret:service-name"
  }
  ```
- Scoped per service (nginx execution role can't read api secrets)

---

## C) Spot Instance Strategy

### Base vs Overflow Architecture

**Configuration**:
- On-Demand Base: 1 instance (always running)
- On-Demand Percentage Above Base: 20%
- Spot: Remaining 80%

**Example Scaling**:
```
ASG Size 1: 1 On-Demand, 0 Spot
ASG Size 2: 1 On-Demand, 1 Spot
ASG Size 5: 2 On-Demand (1 base + 20% of 4), 3 Spot
ASG Size 10: 2 On-Demand (1 base + 20% of 9), 8 Spot
```

### Interruption Behavior

**Spot Interruption 2-minute warning**:
1. EC2 sends termination notice to instance
2. ECS agent detects interruption via `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true`
3. Instance marked as DRAINING (no new tasks)
4. Running tasks gracefully stopped (SIGTERM → SIGKILL after 30s)
5. Tasks rescheduled on other instances
6. ECS capacity provider scales cluster if needed

**Why Users Stay Online**:
- On-Demand baseline (1+ instances) always available
- Tasks spread across multiple instances and AZs
- ALB routes traffic only to healthy tasks
- Capacity provider launches replacement capacity before tasks are killed

## D) Scaling Architecture (I have done this and schedule sclling in many project in past and current org)

### Service-Level Auto-Scaling (Task Count)

**Three scaling policies**:

1. **CPU-based**: Target 70% utilization
   - Scale out when avg CPU > 70% for 60s
   - Scale in when avg CPU < 70% for 300s

2. **Memory-based**: Target 80% utilization
   - Scale out when avg memory > 80% for 60s
   - Scale in when avg memory < 80% for 300s

3. **ALB Request-based**: Target 1000 requests/task
   - Scale out when requests/target > 1000 for 60s
   - Scale in when requests/target < 1000 for 300s

**Fastest trigger wins**: Service scales based on first metric to breach threshold.

### Cluster-Level Auto-Scaling (Instance Count)

**ECS Capacity Provider with Managed Scaling**:
```hcl
managed_scaling {
  status          = "ENABLED"
  target_capacity = 100  # Keep cluster at 100% reservation
  minimum_scaling_step_size = 1
  maximum_scaling_step_size = 10
  instance_warmup_period    = 300  # 5 minutes
}
```

**How it works**:
1. ECS calculates `CapacityProviderReservation`:
   ```
   Reservation = (Sum of task CPU/Memory requests) / (Total cluster capacity) × 100
   ```

2. If reservation > 100%:
   - Capacity provider triggers ASG scale-out
   - New instances launch (Spot first due to 80/20 mix)
   - Instances register with ECS cluster
   - Tasks scheduled on new capacity

3. If reservation < 100% for extended period:
   - Capacity provider triggers ASG scale-in
   - ECS drains instances safely
   - Tasks migrate to remaining instances

### Handling Pending Tasks

**Scenario**: Service wants 10 tasks, cluster can only run 6, 4 tasks PENDING.

**Resolution**:
1. ECS detects PENDING tasks (insufficient CPU/memory on existing instances)
2. Capacity provider sees reservation > 100%
3. ASG scales out by 1-10 instances (based on shortage)
4. New instances come online in ~5 minutes (warmup period)
5. PENDING tasks scheduled immediately on new capacity

**Why it doesn't deadlock**:
- Capacity provider continuously monitors reservation
- Automatic scale-out triggered by resource pressure
- No manual intervention required

---

## E) Operations: Monitoring and Alerting

### Top 5 Critical Monitors

1. **ECS Service Health**
   - Metric: `DesiredTaskCount` vs `RunningTaskCount`
   - Threshold: Alert if running < desired for 5+ minutes
   - Action: Investigate task failures, capacity constraints

2. **ALB Target Health**
   - Metric: `UnHealthyHostCount` > 0
   - Duration: 2 consecutive periods
   - Action: Check task logs, health check endpoint

3. **Spot Interruption Rate**
   - EventBridge rule for EC2 Spot interruptions
   - Alert if >30% of capacity interrupted in 5 minutes
   - Action: Review Spot pricing, consider increasing On-Demand base

4. **Capacity Provider Scaling Lag**
   - Monitor: ECS CapacityProviderReservation metric
   - Alert if >80% for >5 minutes (insufficient cluster capacity)
   - Action: Increase ASG max size or task count

5. **Service CPU/Memory Utilization**
   - Alert on sustained >90% CPU/memory
   - Page on-call if P95 latency >500ms for 5 minutes

### What Pages at 3am

**Critical (Page on-call)**:
1. ALB 5xx > 1% for 5 minutes (deployment issue)
2. ECS Service unable to place tasks (capacity exhaustion)
3. All On-Demand instances down (no Spot baseline)
4. Task failing health checks repeatedly (deployment rollback needed)
5. NAT Gateway down (all egress blocked)

**Warning (Alert only)**:
- High Spot interruption rate
- ASG approaching max capacity
- Individual task failures (if < 50%)
- Elevated ALB response times

---

## Production Readiness Status

**Implemented**:
- ✅ Zero-downtime deployments
- ✅ Secure secrets management
- ✅ Cost-optimized Spot/On-Demand mix
- ✅ Multi-AZ high availability
- ✅ Auto-scaling (service + cluster)
- ✅ Spot interruption handling
- ✅ Least-privilege IAM
- ✅ Private subnet isolation
