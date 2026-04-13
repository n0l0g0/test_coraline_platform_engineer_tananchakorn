# Question 1 — Infrastructure for Deploying Metabase + PostgreSQL

## Overview

This solution provisions a **production-grade Metabase** deployment on AWS using Terraform (IaC). The system is accessible via the public web through an HTTPS-enabled Application Load Balancer, while the PostgreSQL database is fully isolated in private subnets with **zero public internet route**.

---

## Architecture Summary

```
Internet → Route 53 → ALB (HTTPS:443) → ECS Fargate Metabase → RDS PostgreSQL (private)
                                                       ↑
                                             AWS Secrets Manager
                                             (via VPC Endpoint)
```

| Layer | Resource | Details |
|---|---|---|
| DNS | Route 53 | Alias → ALB |
| Load Balancer | ALB | HTTP→HTTPS redirect, TLS 1.3 |
| Application | ECS Fargate | Metabase v0.50, 1 vCPU / 2 GB RAM |
| Database | RDS PostgreSQL 15 | Multi-AZ, encrypted, private only |
| Secrets | AWS Secrets Manager | DB credentials, IAM-scoped access |
| Monitoring | CloudWatch | Logs, metrics, alarms |

---

## Security Design

### PostgreSQL is NOT publicly accessible

- `publicly_accessible = false` on RDS instance
- DB subnets have **no default route** (no IGW, no NAT)
- RDS Security Group allows **only port 5432 from ECS Security Group**
- No route from the internet can reach the DB subnets

### Secrets Management

- Terraform generates a 32-character random password at deploy time
- Credentials stored in **AWS Secrets Manager** as JSON (username, password, host, port, dbname)
- ECS task uses the `secrets:` field — credentials are **never stored in environment variables or task definitions**
- IAM policy scoped to the exact Secret ARN — no wildcard access
- Fetched via **VPC Interface Endpoint** — traffic never leaves the AWS network

### Network Isolation

```
Public Subnets (AZ-A/B):   10.0.1.0/24, 10.0.2.0/24  → ALB, NAT GW
Private App Subnets (AZ-A/B): 10.0.11.0/24, 10.0.12.0/24  → ECS Fargate
Private DB Subnets (AZ-A/B):  10.0.21.0/24, 10.0.22.0/24  → RDS only
```

Security Group rules (principle of least privilege):
- **alb-sg**: Accepts 80/443 from internet; sends to metabase-sg:3000 only
- **metabase-sg**: Accepts :3000 from alb-sg only; sends to rds-sg:5432 and HTTPS for AWS services
- **rds-sg**: Accepts :5432 from metabase-sg only; no egress rules

---

## Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured with appropriate IAM permissions
- ACM certificate ARN (for HTTPS, or ALB will be HTTP-only without cert)

### Required IAM permissions

```
ec2:*, ecs:*, rds:*, elasticloadbalancing:*, secretsmanager:*,
iam:*, cloudwatch:*, logs:*, autoscaling:*, s3:*, application-autoscaling:*
```

---

## File Structure

```
terraform/
├── providers.tf        # AWS provider + Terraform version constraints
├── variables.tf        # All input variables with descriptions and defaults
├── main.tf             # Local values (name_prefix, common_tags)
├── vpc.tf              # VPC, subnets (3 tiers), IGW, NAT GW, route tables, VPC endpoints
├── security_groups.tf  # SG for ALB, Metabase, RDS, VPC endpoints
├── secrets.tf          # Random password + Secrets Manager secret + resource policy
├── iam.tf              # ECS execution role + task role (least privilege)
├── rds.tf              # RDS PostgreSQL, subnet group, parameter group, alarms
├── ecs.tf              # ECS cluster, task definition, service, auto-scaling
├── alb.tf              # ALB, target group, listeners (HTTP redirect + HTTPS), alarms
└── outputs.tf          # Metabase URL, endpoints, ARNs
```

---

## Local Docker Deployment

Run Metabase + PostgreSQL locally in a single command — no AWS account required.

### 1. Start the stack

```bash
cd question-1/docker
docker compose up -d
```

### 2. Wait for Metabase to initialize (~2 minutes)

```bash
docker compose logs -f metabase

```

### 3. Open Metabase

```
http://localhost:3000
```

Complete the setup wizard. When asked for a database to connect, use:

| Field | Value |
|---|---|
| Database type | PostgreSQL |
| Host | `postgres` |
| Port | `5432` |
| Database name | `testcoralineappdb` |
| Username | `testcoraline` |
| Password | `testcoraline2026` |

### 4. Useful commands

```bash

docker compose ps


curl -s http://localhost:3000/api/health


docker compose exec postgres psql -U testcoraline -d testcoralineappdb


docker compose down


docker compose down -v
```

### Architecture (local)

```
Host (browser) → localhost:3000 → Metabase container
                                         ↓ (internal network only)
                               PostgreSQL container
                               (NOT exposed to host)
```

PostgreSQL is on the internal Docker network only — not reachable from the host directly, mirroring the AWS architecture where the DB has no public route.

---

## How to Deploy (AWS)

### 1. Clone the repository

```bash
git clone <repo-url>
cd question-1/terraform
```

### 2. Configure variables

Create a `terraform.tfvars` file:

```hcl
aws_region      = "ap-southeast-1"
environment     = "prod"
project_name    = "coraline-metabase"

# Required for HTTPS
certificate_arn = "arn:aws:acm:ap-southeast-1:123456789:certificate/xxxx"

# RDS settings
db_multi_az     = true
db_instance_class = "db.t3.small"

# Metabase
metabase_desired_count = 1
```

### 3. Initialize and deploy

```bash

terraform init


terraform plan -out=tfplan


terraform apply tfplan
```

### 4. Get the Metabase URL

```bash
terraform output metabase_url
```

Wait approximately **3–5 minutes** for ECS tasks to start and pass health checks. Metabase initialization can take up to 2 minutes on first run.

---

## How to Test

### 1. Verify Metabase is accessible

```bash

ALB_DNS=$(terraform output -raw alb_dns_name)


curl -s "https://${ALB_DNS}/api/health"

```

### 2. Verify PostgreSQL is NOT publicly accessible

```bash

RDS_HOST=$(terraform output -raw rds_endpoint)


psql -h "${RDS_HOST}" -U metabase_admin -d metabase -c "SELECT 1;" 2>&1

```

### 3. Verify secrets are correctly set

```bash
aws secretsmanager get-secret-value \
  --secret-id "coraline-metabase-prod/db/credentials" \
  --query SecretString --output text | python3 -m json.tool
```

### 4. Check ECS service health

```bash
aws ecs describe-services \
  --cluster coraline-metabase-prod \
  --services coraline-metabase-prod \
  --query "services[0].{Running:runningCount,Desired:desiredCount,Status:status}"
```

---

## How to Destroy

```bash

terraform apply -var="db_deletion_protection=false" -target=aws_db_instance.metabase


terraform destroy
```



---

## Assumptions

1. **AWS is the target cloud provider** — specifically `ap-southeast-1` (Singapore) as the closest region to Bangkok.
2. **ECS Fargate** is used instead of EC2 to minimize operational overhead, as specified in the Metabase Docker docs.
3. **ACM certificate** must be provisioned separately (DNS validation via Route 53 recommended). Without it, the ALB listener runs on HTTP only.
4. **Remote state** (S3 + DynamoDB locking) is shown as commented-out backend config — configure before team use.
5. **Metabase v0.50.0** is pinned for reproducibility. Update `metabase_image` variable to upgrade.
6. **Multi-AZ RDS** is enabled by default for production. Set `db_multi_az = false` for dev/staging to reduce cost.
7. **SNS notifications** for CloudWatch alarms are left as empty lists — configure with your alerting channels (PagerDuty, Slack webhook, email).

---

## Reference

- [Metabase Docker documentation](https://www.metabase.com/docs/latest/installation-and-operation/running-metabase-on-docker)
- [AWS ECS Fargate documentation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html)
- [AWS Secrets Manager with ECS](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html)
