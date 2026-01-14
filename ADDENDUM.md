# ADDENDUM.md

## Production Stress Test Scenarios

This document analyzes critical failure modes and operational behaviors in production.

---

## 1) Spot Failure During Deployment

**Scenario**: During a deployment, 60% of Spot instances are reclaimed by AWS.

### Step-by-Step Sequence

#### Initial State
- ASG: 5 instances (1 On-Demand, 4 Spot)
- ECS Service: 8 tasks running (distributed across instances)
- Deployment triggered: New task definition being rolled out

#### T+0: Spot Interruption Warnings Received
```
AWS sends 2-minute warning to 3 Spot instances (60% of 4 Spot)
```

1. **ECS Agent Response**:
   - Affected instances marked as DRAINING
   - No new tasks scheduled on these instances
   - Existing tasks continue running normally

2. **Running Tasks**:
   - Tasks on DRAINING instances: Continue serving traffic
   - Tasks on healthy instances: Unaffected
   - New deployment tasks: Scheduled only on healthy instances

3. **Pending Tasks**:
   - Deployment launched 8 new tasks (200% max = 16 total)
   - New tasks waiting for placement: Queue up as PENDING

#### T+30s: Capacity Provider Detects Resource Shortage
```
CapacityProviderReservation > 100% (16 desired tasks, capacity for 10)
```

4. **Capacity Provider Action**:
   - Triggers ASG scale-out
   - Target: Add sufficient capacity for all PENDING tasks
   - ASG attempts Spot first (80/20 mix), falls back to On-Demand if needed

5. **ASG Response**:
   - Launches 2 new instances (1 Spot, 1 On-Demand based on 80/20 ratio)
   - If Spot unavailable: Launches On-Demand
   - Instance warmup: ~60-90s for ECS registration

#### T+90s: New Capacity Available
```
New instances registered with ECS cluster
```

6. **Task Scheduling**:
   - PENDING tasks immediately scheduled on new instances
   - Tasks start, pull images (cached if previously deployed)
   - Tasks register with ALB target groups

#### T+120s: Spot Instances Terminate
```
3 Spot instances shut down (2-minute warning expires)
```

7. **Task Migration**:
   - Tasks on terminated instances forcefully stopped (SIGKILL)
   - ECS automatically replaces stopped tasks
   - New tasks scheduled on remaining capacity
   - ALB removes terminated instances from rotation

#### T+150s: New Tasks Healthy
```
New deployment tasks pass 2 consecutive health checks (60s total)
```

8. **ALB Behavior**:
   - ALB marks new tasks as healthy
   - Begins routing traffic to new tasks
   - Old tasks deregister (30s connection draining)

#### T+180s: Deployment Complete
```
Old tasks terminated, deployment successful
```

9. **Final State**:
   - ASG: 4 instances (2 On-Demand, 2 Spot)
   - All 8 tasks running new version
   - Capacity provider may scale in excess capacity after cooldown

### Where Does New Capacity Come From?

1. **First**: Existing On-Demand baseline (1 instance always available)
2. **Second**: Remaining Spot instances (those not interrupted)
3. **Third**: New Spot instances launched by ASG (if available)
4. **Fourth**: New On-Demand instances (if Spot unavailable)

### Why Is There No Downtime?

1. **On-Demand Baseline**: 1+ On-Demand instances always running (never interrupted)
2. **Gradual Draining**: 2-minute warning allows graceful task migration
3. **ALB Intelligence**: Routes traffic only to healthy tasks
4. **Deployment Buffer**: 200% max allows running old + new tasks simultaneously
5. **Capacity Provider**: Proactively scales cluster before tasks become PENDING
6. **Multi-AZ**: Tasks spread across availability zones (single AZ loss is survivable)

### Timing Analysis
```
T+0   : Spot warning (tasks still running)
T+30  : Scale-out triggered
T+90  : New capacity online
T+120 : Spot instances terminate (tasks rescheduled)
T+180 : Deployment complete
```
**Maximum Impact**: Brief (<3 minutes) of reduced capacity, but no dropped requests due to ALB routing and On-Demand baseline.

---

## 2) Secrets Break at Runtime

**Scenario**: IAM permission removed from task execution role, preventing secret access.

### What Breaks

#### Task Startup Phase
```
ECS Task State: PENDING → PROVISIONING → STOPPED (error)
```

**Failure Point**: Task execution role cannot read Secrets Manager

**Error Message** (in ECS events):
```
ResourceInitializationError: unable to pull secrets or registry auth: 
execution resource retrieval failed: unable to retrieve secret from arn:aws:secretsmanager:...: 
AccessDeniedException: User is not authorized to perform: secretsmanager:GetSecretValue
```

**What Actually Happens**:
1. ECS agent provisions task (allocates CPU/memory)
2. Task execution role attempts to pull secrets
3. Secrets Manager API call fails (403 Forbidden)
4. Task transitions to STOPPED state immediately
5. Container never starts (no application runtime)

#### Impact on Service
- **Existing Tasks**: Continue running (secrets only pulled at startup)
- **New Tasks**: All fail to start (0% success rate)
- **Deployments**: Fail immediately (circuit breaker triggers rollback)
- **Auto-Scaling**: Unable to add capacity (new tasks fail)

### Detection

**CloudWatch Logs** (`/ecs/service-name`):
```
No logs generated (container never starts)
```

**ECS Service Events**:
```
service nginx was unable to place a task because no container instance met all of its requirements. 
Reason: ResourceInitializationError: unable to pull secrets
```

**CloudWatch Metrics**:
- `RunningTaskCount` drops to 0 (if all tasks restart)
- `DesiredTaskCount` > `RunningTaskCount` (persistent gap)
- `TaskStartFailed` metric spikes

**ALB Health Checks**:
- Unhealthy host count increases
- Eventually all targets unhealthy (if all tasks restart)

### Recovery Steps

#### Immediate Actions (STOP THE BLEEDING)
1. **Identify IAM Issue**:
   ```bash
   aws ecs describe-services \
     --cluster production-cluster \
     --services nginx
   # Check events for "AccessDeniedException"
   ```

2. **Restore IAM Permissions**:
   ```bash
   # Re-attach secrets policy to execution role
   aws iam put-role-policy \
     --role-name nginx-execution-role \
     --policy-name nginx-secrets-access \
     --policy-document file://secrets-policy.json
   ```

3. **Verify Permissions**:
   ```bash
   # Test secret access with execution role
   aws secretsmanager get-secret-value \
     --secret-id nginx \
     --profile execution-role-profile
   ```

4. **Force New Deployment** (to restart tasks with fixed permissions):
   ```bash
   aws ecs update-service \
     --cluster production-cluster \
     --service nginx \
     --force-new-deployment
   ```

#### Safe Recovery (NO SECRET LEAKAGE)
- **DO NOT**: Add secrets to environment variables in task definition
- **DO NOT**: Output secrets to CloudWatch Logs for debugging

**Correct Approach**:
1. Fix IAM permissions (as above)
2. Test secret access via AWS CLI (with temporary credentials)
3. Redeploy service (tasks pull secrets at startup)
4. Monitor task startup success via ECS events

### How to Avoid Secret Leakage

**Prevention Measures**:
1. **Least Privilege IAM**: Execution role can only read its own service's secrets
   ```json
   {
     "Resource": "arn:aws:secretsmanager:us-east-1:123456789:secret:nginx-*"
   }
   ```

2. **Secrets in Memory Only**: Never log, cache, or persist secrets
   ```python
   # WRONG
   print(f"Database password: {os.getenv('DB_PASSWORD')}")
   
   # CORRECT
   db_password = os.getenv('DB_PASSWORD')
   # Use directly, never log
   ```

3. **CloudWatch Log Filtering**: Enable log pattern filtering to detect accidental leaks
   ```json
   {
     "filterPattern": "[password, secret, key, token]"
   }
   ```

4. **Secrets Rotation**: Regular rotation limits exposure window if leaked

5. **Audit Logging**: CloudTrail tracks all Secrets Manager access

---

## 3) Pending Task Deadlock

**Scenario**: Service wants 10 tasks, cluster can run 6, 4 tasks are PENDING.

### Capacity Calculation

**Cluster Capacity**:
```
Total cluster CPU:    6 instances × 2048 CPU = 12,288 CPU units
Total cluster Memory: 6 instances × 3840 MB = 23,040 MB
```

**Task Requirements** (per task):
```
CPU:    256 units (0.25 vCPU)
Memory: 512 MB
```

**Current Utilization**:
```
Running tasks: 6
CPU used:    6 × 256 = 1,536 / 12,288 = 12.5%
Memory used: 6 × 512 = 3,072 / 23,040 = 13.3%
```

**Why only 6 tasks?** (Not actually a CPU/memory issue)

**Real Issue**: Task placement constraints (AZ balance, instance availability)
- Possible causes: Instances draining, unhealthy instances, AZ imbalance

### What Triggers Capacity Increase?

**ECS Capacity Provider Managed Scaling**:
```hcl
target_capacity = 100  # Goal: Keep reservation at 100%
```

**Calculation**:
```
CapacityProviderReservation = (Task CPU/Memory requests) / (Available capacity) × 100
                            = (10 tasks × 256 CPU) / (12,288 CPU) × 100
                            = 20.8%  # Well below 100% - no scale needed!
```

**Wait, there's still capacity! Why PENDING tasks?**

### Real Scenario: Instance Draining

**Corrected Setup**:
- 2 instances are DRAINING (Spot interruption or maintenance)
- Only 4 instances ACTIVE
- Available capacity: 4 × 2048 = 8,192 CPU

**Revised Calculation**:
```
CapacityProviderReservation = (10 × 256) / (8,192) × 100 = 31.25%
```

Still below 100%! **But**: ECS uses bin-packing and placement strategies.

**Actual Issue**: Task distribution across AZs
- AZ-1: 2 instances (full), AZ-2: 2 instances (full)
- Each instance can only run ~2 tasks (based on memory/CPU)
- 4 tasks PENDING due to even AZ distribution requirement

### Why It Doesn't Deadlock

**Capacity Provider Response** (even at 31% reservation):
1. ECS detects PENDING tasks for >5 minutes
2. Capacity provider triggers scale-out (proactive)
3. ASG launches 2 new instances (1 per AZ)
4. New instances come online (~5 minutes)
5. PENDING tasks scheduled immediately

**Critical Design Element**:
```hcl
managed_termination_protection = "ENABLED"
```
Prevents ASG from terminating instances with running tasks, ensuring no capacity loss during scale events.

### Timeline
```
T+0   : Service scales to 10 tasks, 4 become PENDING
T+5   : Capacity provider detects persistent PENDING state
T+6   : ASG scale-out triggered (target size: 6 → 8)
T+11  : New instances online, registered with ECS
T+12  : PENDING tasks scheduled, start running
T+15  : All 10 tasks healthy and serving traffic
```

**No Deadlock** Because:
1. Capacity provider continuously monitors PENDING tasks
2. Automatic scale-out when reservation exceeds target
3. No manual intervention required
4. Scale-out cooldown prevents thrashing (5 minutes)

---

## 4) Deployment Safety

**Scenario**: Rolling deployment with health check validation.

### When Do New Tasks Start?

**Deployment Initiated**:
```
Current: 2 tasks running (v1.0)
Target:  2 tasks running (v2.0)
Max:     200% = 4 tasks total allowed
Min:     100% = 2 tasks minimum required
```

**Task Start Sequence**:
1. **T+0**: ECS launches 2 new tasks (v2.0) immediately
2. **T+5**: Tasks transition PENDING → PROVISIONING
3. **T+20**: Tasks pull image, start containers
4. **T+30**: Containers running, listening on port 80

**Total Time to Start**: ~30-60 seconds (depends on image size, cached layers)

### When Do Old Tasks Stop Receiving Traffic?

**ALB Health Check Timeline**:
```
T+30: First health check (new tasks)
T+60: Second health check (new tasks) → HEALTHY
```

**Traffic Shift**:
1. **T+60**: New tasks marked HEALTHY in target group
2. **T+60**: ALB begins routing requests to new tasks
3. **T+60**: Old tasks deregister from ALB (deregistration delay: 30s)
4. **T+90**: Old tasks stop receiving NEW connections
5. **T+90-120**: Existing connections drain (complete open requests)

**Important**: Old tasks still process in-flight requests during draining period.

### When Are Old Tasks Killed?

**Task Termination Sequence**:
```
T+90:  Deregistration complete, no new traffic
T+90:  ECS sends SIGTERM to container (graceful shutdown signal)
T+120: Container has 30s to finish processing and shut down cleanly
T+120: If still running: ECS sends SIGKILL (forceful termination)
```

**Grace Period**: 30 seconds for application to:
- Complete in-flight requests
- Close database connections
- Flush logs/metrics
- Save state


### What If New Tasks Fail Health Checks?

**Circuit Breaker Activation**:
```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

**Failure Scenario**:
1. **T+60**: New tasks fail first health check (e.g., app crash, wrong port)
2. **T+90**: New tasks fail second health check → UNHEALTHY
3. **T+95**: ECS detects deployment failure (0% healthy new tasks)
4. **T+100**: Circuit breaker triggers automatic rollback
5. **T+105**: ECS stops new deployment, keeps old tasks running
6. **T+110**: Old tasks continue serving traffic (zero downtime)

**ECS Service Event**:
```
ECS deployment circuit breaker: tasks failed to start. 
Automatically rolling back to previous task definition.
```

**Result**: Deployment fails safely, users unaffected, old version continues running.

### Summary Timeline
```
T+0   : New tasks launched
T+30  : New tasks running
T+60  : New tasks healthy, receive traffic
T+90  : Old tasks deregister, drain connections
T+120 : Old tasks terminated (if graceful shutdown complete)
```

**If health checks fail**: Rollback at T+100, old tasks never deregister.

---

## 5) TLS, Trust Boundary, Identity

### Where Is TLS Terminated?

**Current Setup**: HTTP-only (TLS not configured)

**Production Setup** (recommended):
```
Internet (HTTPS)
    ↓
Application Load Balancer (TLS termination)
    ↓ (HTTP - internal VPC)
ECS Tasks (private subnet)
```

**TLS Certificate**:
- Managed via AWS Certificate Manager (ACM)
- Attached to ALB HTTPS listener (port 443)
- Automatic renewal by AWS

**Why Terminate at ALB**:
1. Centralized certificate management
2. Offload TLS overhead from containers
3. Simplified application deployment
4. ALB handles cipher suite selection, TLS version enforcement

**Traffic Flow**:
```
Client → ALB:443 (HTTPS/TLS)
ALB → Task:80 (HTTP, internal)
```

### What AWS Identity Does the Container Run As?

**Separate Roles**:

#### 1. Task Execution Role (Startup Only)
```
Role: nginx-execution-role
Used By: ECS Agent (not container)
Purpose: Pull image, read secrets, write logs
```

**Permissions**:
- `ecr:GetAuthorizationToken`
- `ecr:BatchCheckLayerAvailability`
- `ecr:GetDownloadUrlForLayer`
- `secretsmanager:GetSecretValue` (scoped to service vault)
- `logs:CreateLogStream`, `logs:PutLogEvents`

**When Used**: Task startup only (before container runs)

### What AWS Resources Can It Access?

**With Current Configuration** (execution role only):
- **Container itself**: Cannot access AWS APIs directly
- **No AWS SDK calls**: Application would receive 403 errors

**Least Privilege Principle**:
- Execution role: Only permissions needed for task startup
- Task role: Only permissions needed for application logic
- Never combine roles (separation of concerns)

## 6) Cost Floor

**Scenario**: Traffic drops to zero for 12 hours.

### What Are You Still Paying For?

**Why Can't We Scale to Zero?**
- `asg_min_size = 2` (enforced by Terraform)
- ECS tasks require running instances
- Capacity provider cannot scale below ASG minimum

### What Would You Change to Reduce Cost Without Reducing Safety?

#### Option 1: Reduce ASG Minimum (Risky)
```hcl
asg_min_size = 1  # Down from 2
```

**Impact**:
- **Risk**: Single point of failure, no redundancy
- **Not Recommended**: Violates availability requirements

#### Option 2: Scheduled Scaling (Dev/Staging Only) (I have implemented it personally in project and it's very good feature)
```hcl
resource "aws_autoscaling_schedule" "scale_down" {
  scheduled_action_name  = "scale-down-overnight"
  min_size               = 1
  max_size               = 10
  desired_capacity       = 1
  recurrence             = "0 22 * * *"  # 10 PM daily
  autoscaling_group_name = aws_autoscaling_group.ecs.name
}

resource "aws_autoscaling_schedule" "scale_up" {
  scheduled_action_name  = "scale-up-morning"
  min_size               = 2
  max_size               = 10
  desired_capacity       = 2
  recurrence             = "0 6 * * *"  # 6 AM daily
  autoscaling_group_name = aws_autoscaling_group.ecs.name
}
```

**Impact**:
- Saves ~$20-25/month (16 hours/day of reduced capacity)
- **Risk**: Higher instance start latency during scale-up

#### Option 3: Fargate Spot (Alternative Architecture) (Also implemnted in my current org and it's very precise as cost saving)
```hcl
# Move to Fargate Spot for dev/staging
capacity_provider = "FARGATE_SPOT"
```

**Impact**:
- Pay per task, not per instance
- Zero cost when no tasks running
- **Savings**: ~$50/month in low-traffic environments
- **Trade-off**: Higher per-task cost, less control over infrastructure

#### Recommended Approach (Production)

**Keep Current Setup** but add:
1. **VPC Endpoints**: Reduce data transfer costs
2. **Reserved Instances**: 1-year RI for On-Demand baseline (~40% savings)
3. **CloudWatch Log Optimization**: Reduce retention to 7 days for non-prod
4. **ALB Optimization**: Share ALB across multiple applications

**Estimated Savings**: ~$20-30/month without sacrificing availability

---

## 7) Failure Modes

### Failure Mode 1: NAT Gateway Failure

**Detection**:
- CloudWatch Alarm: `NATGatewayPacketDropCount` > 0
- ECS Task Events: "Task failed to start: unable to pull image"
- Logs: Connection timeouts to ECR, Secrets Manager

**Blast Radius**:
- **Scope**: All ECS tasks in private subnets
- **Impact**: Cannot pull images, read secrets, write logs
- **Existing Tasks**: Continue running (already started)
- **New Tasks**: Fail to start (no egress)
- **User Impact**: No new deployments, no auto-scaling

**Mitigation**:
1. **Immediate**: 
   - NAT Gateway is highly available (AWS-managed)
   - If failed: AWS automatically creates new NAT (~5 minutes)
   - Monitor NAT Gateway health via CloudWatch

2. **Alternative**: VPC Endpoints (bypass NAT for AWS services)

**Recovery Time**: 5-10 minutes (AWS auto-recovery)

### Failure Mode 2: All Spot Instances Reclaimed Simultaneously

**Detection**:
- EventBridge: Multiple EC2 Spot interruption warnings
- ECS Cluster: `RegisteredContainerInstancesCount` drops rapidly
- CloudWatch: `CapacityProviderReservation` spikes to 150-200%

**Blast Radius**:
- **Scope**: 80% of cluster capacity (all Spot instances)
- **Impact**: Tasks rescheduled to On-Demand baseline
- **User Impact**: Brief latency increase (30-60s), no dropped requests

**Mitigation**:
1. **Design Protection**:
   - On-Demand baseline: 1+ instances always available
   - Capacity provider: Launches On-Demand if Spot unavailable
   - Multi-AZ: Diversifies interruption risk

2. **Immediate Response**:
   ```bash
   # Manually increase On-Demand percentage if Spot repeatedly fails
   aws autoscaling update-auto-scaling-group \
     --auto-scaling-group-name production-cluster-asg \
     --on-demand-percentage-above-base-capacity 40  # Up from 20%
   ```

3. **Monitoring**:
   - Alert if Spot interruption rate > 30% in 5 minutes
   - Automatic scale-out to On-Demand if Spot unavailable

**Recovery Time**: 2-5 minutes (capacity provider scales cluster)

### Failure Mode 3: Application Health Check Endpoint Fails

**Detection**:
- ALB: `UnHealthyHostCount` = all targets
- ECS: Tasks remain RUNNING (but failing health checks)
- Logs: Application crashes, OOM kills, or bugs

**Blast Radius**:
- **Scope**: All tasks for specific service
- **Impact**: ALB stops routing traffic (all targets unhealthy)
- **User Impact**: HTTP 503 errors (no healthy targets)

**Mitigation**:
1. **Circuit Breaker** (Already Configured):
   ```hcl
   deployment_circuit_breaker {
     enable   = true
     rollback = true
   }
   ```
   - Deployment rolls back automatically
   - Previous version restored

2. **Manual Intervention**: (Can also be done using GUI in AWS console reather than AWS CLI)
   ```bash
   # Rollback to previous task definition
   aws ecs update-service \
     --cluster production-cluster \
     --service nginx \
     --task-definition nginx:42  # Previous working version
   ```

3. **Root Cause Analysis**:
   - Check CloudWatch Logs for application errors
   - Review task definition changes (env vars, secrets)
   - Test health check endpoint: `curl http://task-ip/`

**Recovery Time**: 
- Automatic (circuit breaker): 5-10 minutes
- Manual rollback: 2-5 minutes
- Fix and redeploy: 15-30 minutes

---|
