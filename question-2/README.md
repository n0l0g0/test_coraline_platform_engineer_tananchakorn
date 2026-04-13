# Question 2 — Architecture & CI/CD Pipeline Design

## Overview

This document describes the architecture and CI/CD pipeline for a multi-service internal web application that connects to multiple data sources. The system supports three environments (dev / staging / prod) and includes frontend, API, and workflow orchestration (Apache Airflow) services.

---

## 1. Architecture Overview

### System Components

| Service | Technology | Purpose |
|---|---|---|
| **Frontend** | React + Nginx | Web UI served to users |
| **API Service** | FastAPI (Python) | REST API, connects to DB + external systems |
| **Airflow** | Apache Airflow (CeleryExecutor) | Workflow orchestration, DAG scheduling, data pipelines |
| **PostgreSQL** | AWS RDS | Application DB + Airflow metadata DB |
| **Redis** | AWS ElastiCache | Celery broker (Airflow) + API caching |
| **Nginx Ingress** | Kubernetes Ingress | Traffic routing, TLS termination |
| **CloudFront** | AWS CDN | Frontend static asset distribution (prod) |

### Deployment Platform

All services run on **Amazon EKS (Kubernetes)** with the following strategy:

- **Dev**: Shared EKS cluster, isolated by namespace (`dev`)
- **Staging**: Dedicated EKS cluster, namespace `staging` — production-like config
- **Prod**: Dedicated EKS cluster, high-availability, multi-AZ

See: [`diagram/architecture.html`](diagram/architecture.html)

---

## 2. Environment Strategy

### Environment Separation

```
                  ┌──────────┐      ┌───────────┐      ┌──────────┐
  git merge ──▶   │   Dev    │─────▶│  Staging  │──▶──▶│   Prod   │
                  │ (auto)   │ auto │ (auto+    │ manual│ (manual  │
                  │          │ after│ tests)    │ aprvl │ approval)│
                  └──────────┘ smoke└───────────┘      └──────────┘
```

| Aspect | Dev | Staging | Prod |
|---|---|---|---|
| **Deployment** | Auto on merge to `main` | Auto after dev smoke tests | Manual approval (Tech Lead / PO) |
| **EKS** | Shared cluster, namespace: `dev` | Dedicated cluster | Dedicated cluster |
| **Replicas** | 1 per service | 2 per service | 3+ with HPA |
| **Database** | RDS t3.micro (minimal) | RDS t3.small (prod-like, masked data) | RDS t3.large Multi-AZ |
| **TLS** | Internal only | Internal cert | ACM public cert |
| **Feature flags** | All features ON | Same as prod | Controlled rollout |

### Infrastructure per Environment (Terraform workspaces)

```bash

terraform workspace select dev
terraform apply -var-file=environments/dev.tfvars

terraform workspace select staging
terraform apply -var-file=environments/staging.tfvars

terraform workspace select prod
terraform apply -var-file=environments/prod.tfvars
```

---

## 3. Configuration & Secret Management

### Configuration (non-sensitive)

Managed via **Helm values files** per environment:

```
charts/api/
├── values.yaml              # Base defaults
├── values.dev.yaml          # Dev overrides
├── values.staging.yaml      # Staging overrides
└── values.prod.yaml         # Prod overrides
```

Example override pattern:
```yaml

replicaCount: 3
resources:
  limits:
    memory: "1Gi"
    cpu: "500m"
config:
  EXTERNAL_API_URL: "https://api.partner.example.com"
  DB_POOL_SIZE: "20"
  LOG_LEVEL: "WARNING"
```

### Secret Management (sensitive)

**Flow**: AWS Secrets Manager → External Secrets Operator → Kubernetes Secret

```
Developer creates secret in AWS Secrets Manager
        ↓
External Secrets Operator (ESO) running in K8s
        ↓
ExternalSecret CRD → synced as native K8s Secret (refreshInterval: 1h)
        ↓
Pod mounts Secret as env vars / volume
```

**Never** store secrets in:
- Git repository (even encrypted)
- Docker images
- Kubernetes ConfigMaps
- Environment variables in CI/CD pipeline logs

### External System Connections

| System | Connection Method | Auth |
|---|---|---|
| On-premise DB | AWS Site-to-Site VPN | mTLS + username/password from Secrets Manager |
| Cloud external DB | AWS PrivateLink | IAM role + credential rotation |
| Third-party REST APIs | HTTPS | API keys from Secrets Manager |
| SFTP / File storage | VPN tunnel | SSH key from Secrets Manager |

All external credentials are:
- Stored in AWS Secrets Manager (never in code)
- Rotated automatically (where supported)
- Accessed via VPC endpoints (no public route)
- Audited via CloudTrail

---

## 4. CI/CD Pipeline

### Pipeline Flow

```
Push → PR → CI (parallel):
  ├── Secret Scan (Gitleaks + TruffleHog)
  ├── Lint & Format (ESLint, Ruff, Prettier)
  ├── Unit Tests (≥80% coverage)
  ├── SAST (Semgrep + CodeQL)
  └── SCA (Trivy fs + Snyk)
           ↓ All gates pass
        Docker Build (multi-stage, distroless)
        Container Scan (Trivy image)
        SBOM Generation (Syft → SPDX-JSON)
           ↓ Merge to main
        Push to ECR (digest tag)
        Sign with Cosign (keyless SLSA L2)
           ↓
  🟢 Auto-deploy → Dev → Smoke Tests
           ↓ pass
  🟡 Auto-promote → Staging → Integration Tests + Load Tests
           ↓ pass + manual approval
  🔴 Production → Blue/Green or Canary Deploy → Health Verification
```

See: [`diagram/cicd-pipeline.html`](diagram/cicd-pipeline.html)

### GitHub Actions Workflows

| File | Trigger | Purpose |
|---|---|---|
| `.github/workflows/ci.yml` | PR + push to main | All security gates + build + scan + sign |
| `.github/workflows/cd.yml` | CI success + manual | Deploy dev → staging → prod |

### Security Gates (all blocking on merge)

| Gate | Tool | Threshold |
|---|---|---|
| Secret scan | Gitleaks + TruffleHog | Any secret = block |
| SAST | Semgrep + CodeQL | Any HIGH = block |
| SCA | Trivy + Snyk | CRITICAL CVE = block |
| Container scan | Trivy image | CRITICAL/HIGH CVE = block |
| Coverage | pytest-cov | < 80% = block |
| Image signing | Cosign + Kyverno | Unsigned image = reject in K8s |

---

## 5. System Stability & Operations

### Health Checks (per service)

```yaml

livenessProbe:
  httpGet:
    path: /api/v1/health/live
    port: 8000
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /api/v1/health/ready
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 3

startupProbe:
  httpGet:
    path: /api/v1/health/live
    port: 8000
  initialDelaySeconds: 0
  periodSeconds: 5
  failureThreshold: 30   # 150s max startup time
```

### Monitoring Stack

| Layer | Tool | Metrics |
|---|---|---|
| **Metrics** | Prometheus + Thanos | CPU, memory, request rate, latency, error rate |
| **Dashboards** | Grafana | Per-service SLO boards, infra overview |
| **Logs** | Fluent Bit → Elasticsearch → Kibana | Structured JSON, log retention 30d |
| **Tracing** | OpenTelemetry → Jaeger | Distributed request tracing |
| **Alerting** | AlertManager → PagerDuty + Slack | SLO breach alerts, error spikes |
| **Uptime** | Blackbox exporter | External endpoint monitoring |

### SLO Targets (Production)

| Metric | SLO | Alert Threshold |
|---|---|---|
| API availability | 99.9% | < 99.5% → page |
| API latency P99 | < 500ms | > 500ms → warn |
| Error rate | < 1% | > 1% → page |
| Airflow DAG success rate | > 95% | < 90% → page |

### Alerting Strategy

```
Severity CRITICAL → PagerDuty (on-call engineer, 5-min escalation)
Severity WARNING  → Slack #platform-alerts channel
Severity INFO     → Grafana annotation only
```

---

## 6. Promote / Release Strategy

### Dev → Staging (Automatic)
1. CI passes on `main` branch
2. CD deploys to `dev` namespace
3. Smoke tests run automatically against dev
4. If all pass → auto-promote to `staging`
5. Full integration + performance tests run
6. Slack notification sent to `#releases` channel

### Staging → Production (Manual Approval)
1. GitHub Environment protection rule requires approval from **1 of**: Tech Lead, Product Owner
2. Approver reviews test results and diff summary in Slack
3. On approval → CD promotes to production via GitOps commit
4. ArgoCD triggers Argo Rollouts (Canary: 10% → 25% → 50% → 100%)
5. Automated health check runs for 5 minutes
6. If degraded → auto-rollback to previous image tag

### Rollback Options

| Scenario | Method | Time to recover |
|---|---|---|
| Automatic (health check fails) | ArgoCD Rollout undo | < 5 minutes |
| Manual (operator initiated) | `git revert HEAD` in GitOps repo | < 3 minutes |
| Database migration issue | Pre-prepared rollback SQL script | 10–30 minutes |
| Helm rollback | `helm rollback <release> <revision>` | < 2 minutes |

### Hotfix Process

```bash

git checkout -b hotfix/fix-critical-bug main


git push origin hotfix/fix-critical-bug


```

---

## 7. Canary Deployment Strategy

See: [`diagram/canary-deployment.html`](diagram/canary-deployment.html)

### Overview

Production deployments use **Argo Rollouts** with a 4-phase canary strategy for user-facing services and **Blue/Green** for stateful services (Airflow Scheduler).

### Canary Strategy per Service

| Service | Strategy | Reason |
|---|---|---|
| **Frontend** | Canary (header-based → weight) | UI changes — test with `X-Canary: true` before real traffic |
| **API Service** | Canary (weight-based) | Highest risk — direct user data impact |
| **Airflow Webserver** | Canary (header-based → weight) | Internal tool — conservative approach |
| **Airflow Scheduler** | Blue/Green | Stateful — must have exactly 1 active instance at all times |

### Traffic Progression

```
Phase 0: 0%   (Header-only: X-Canary: true) → QA validates 5 min
Phase 1: 10%  → AnalysisRun (2 min) → promote
Phase 2: 25%  → AnalysisRun (5 min) → promote
Phase 3: 50%  → AnalysisRun (5 min) → manual gate (empty pause: {})
Phase 4: 100% → health check → release complete
```

### Automated Analysis (AnalysisTemplate)

At every pause, an **AnalysisRun** queries Prometheus and must pass ALL of:

| Metric | Query | Threshold | Fail Limit |
|---|---|---|---|
| HTTP 5xx error rate | `rate(http_requests_total{status=~"5.."}[2m])` | < 1% | 1/10 |
| P99 latency | `histogram_quantile(0.99, ...)` | < 500ms | 1/10 |
| Pod restart count | `increase(kube_pod_container_status_restarts_total[5m])` | = 0 | 0/5 |
| HTTP success rate | `rate(http_requests_total{status=~"2..\|3.."}[2m])` | > 99% | 1/10 |
| CPU utilization | `rate(container_cpu_usage_seconds_total[2m]) * 100` | < 90% | 2/5 |

If **any metric fails** → AnalysisRun = Failed → Rollout **auto-aborts** → traffic instantly returns to stable → GitOps reverted → PagerDuty alert.

### K8s Manifests

```
question-2/k8s/
├── rollouts/
│   ├── rollout-api.yaml        # API canary rollout + Services + HPA + PDB
│   ├── rollout-frontend.yaml   # Frontend canary with header-based routing
│   └── rollout-airflow.yaml    # Airflow webserver (canary) + scheduler (blue/green)
└── analysis/
    └── analysis-template-api.yaml  # AnalysisTemplate + ClusterAnalysisTemplate
```

### CLI Commands

```bash

kubectl argo rollouts get rollout api-service -n prod --watch


kubectl argo rollouts promote api-service -n prod


kubectl argo rollouts abort api-service -n prod


kubectl argo rollouts promote api-service -n prod --full


kubectl argo rollouts dashboard -n prod
```

---

## 8. Security Architecture Summary

- **Network**: Kubernetes NetworkPolicy (deny-all by default, explicit allow rules)
- **Pods**: Pod Security Standards — restricted profile (non-root, read-only FS, no privilege escalation)
- **RBAC**: Separate ServiceAccount per service, IRSA (IAM Roles for Service Accounts)
- **Secrets**: External Secrets Operator — synced from AWS Secrets Manager, never in Git
- **Images**: Signed with Cosign; Kyverno admission controller rejects unsigned images
- **External**: VPN / PrivateLink for all external connections; no public DB access
- **Supply Chain**: SBOM generated per release (SPDX-JSON); SLSA Level 2 provenance

---

## Assumptions

1. **AWS EKS** is used as the Kubernetes platform, with separate clusters for staging and prod.
2. **ArgoCD** handles GitOps-based deployments using a separate `gitops-helm-values` repository.
3. **Argo Rollouts** enables Blue/Green and Canary strategies in production.
4. **Trunk-based development** with short-lived feature branches and PR-based merges to `main`.
5. **GitHub Advanced Security** (CodeQL) is available on the repository plan.
6. External systems (on-premise DB) are connected via AWS Site-to-Site VPN, managed by infrastructure team.
7. PagerDuty is the primary on-call alerting tool; Slack is used for non-critical notifications.
