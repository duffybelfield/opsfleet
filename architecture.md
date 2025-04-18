# 🏗️ Innovate Inc. Cloud Infrastructure Architecture

## Overview

This document outlines the cloud infrastructure for Innovate Inc., a startup deploying a secure, scalable, and cost-effective web application using AWS services and managed Kubernetes (EKS).

---

## 🌐 Cloud Environment Structure

### AWS Account Structure

| Account         | Purpose                                                 |
|----------------|----------------------------------------------------------|
| **Management** | Central billing, consolidated guardrails, IAM identity center |
| **Development**| Non-prod workloads, experimentation, CI/CD pipeline execution |
| **Production** | Prod workloads, locked down with stricter IAM/SCPs       |
| **Security/Logs** | Centralized logging, security tools (e.g., GuardDuty, CloudTrail) |

- **Tagging Standards**: Enforced across accounts for cost attribution and environment classification.
- **SCPs**: Used to restrict actions by account type, especially to enforce security and prevent drift.

---

## 🌍 Network Design

### VPC Layout

Single-region, highly available VPC with multiple AZs.

| Subnet Type | Contents |
|-------------|----------|
| Public      | ALB, NAT Gateway, CloudFront origin, API Gateway |
| Private     | EKS worker nodes, backend services, PostgreSQL (RDS), Lambdas |

### Security Features

#### 🔒 Ingress Controls

- **CloudFront** + **WAF**: Edge protection for frontend.
- **API Gateway + WAF**: Protects API endpoints from SQLi/XSS/rate-limiting.
- **TLS-only** enforced across all endpoints.

#### 🔐 Egress & Monitoring

- All outbound flows through **NAT Gateways**
- **AWS Network Firewall** for deep packet inspection, DNS filtering, and domain/IP-based egress controls.

#### Access

- No direct access to nodes. Admins use **CloudShell** or a **VPN** (future) for infrastructure access.
- **Flow logs** and **CloudTrail** enabled and exported to centralized log account.

---

## ☸️ Compute Platform (EKS)

### Cluster Management

- **EKS** in private subnets
- **Managed Node Groups** with autoscaling (CPU/memory thresholds)
- **Karpenter** for dynamic node provisioning

### Workloads

- Mixed workloads: backend API, cron jobs, and future ML pipelines.
- Supports **blue/green deployments** for minimal downtime.

### Containerization & Deployment

- Docker images built by **CodeBuild**, pushed to **ECR**
- Daily cron rebuilds ensure patched base layers.
- Vulnerability scans in ECR trigger **CloudWatch Alarms** and **email alerts** if thresholds are met.

---

## 🧪 CI/CD Pipeline

### Tools & Workflow

| Phase                     | Tool                        | Responsibility                                      |
|--------------------------|-----------------------------|----------------------------------------------------|
| Pull Requests             | GitHub                      | PR management, linting via GitHub Actions          |
| Testing & Validation      | CodeBuild                   | Unit/integration tests, reports back to GitHub     |
| Image Build & Push        | CodeBuild                   | Build containers, push to ECR                      |
| Deployment to EKS         | CodePipeline + CodeBuild    | Helm/kubectl deployment, rollback support          |

- Environments: **dev**, **staging**, and **prod** are isolated via CodePipeline stages.
- CD remains entirely in AWS for traceability and reduced external dependencies.

---

## 🛢️ Database Layer

- **Amazon RDS for PostgreSQL**, Multi-AZ enabled.
- SSL required for all connections.
- Backups every **4 hours**, PITR enabled.
- Automated snapshots + retention policy.
- No read replicas yet, analytics offloaded to future services.

---

## 🛡️ Security Operations & Future SIEM

### Current Logging

| Source              | Destination                     |
|---------------------|----------------------------------|
| CloudTrail          | S3 + CloudWatch Logs             |
| VPC Flow Logs       | S3 + CloudWatch Logs             |
| EKS Audit Logs      | CloudWatch                       |
| WAF/API Gateway     | CloudWatch + S3 via Kinesis      |
| RDS Logs            | CloudWatch                       |

### Future: SIEM

- **Amazon Security Lake** + Athena/OpenSearch
- Feeds from GuardDuty, CloudTrail, Inspector, WAF, EKS, VPC, and more.
- Custom rules, correlation, alerting
- Scalable, OCSF-compatible, ISO 27001 aligned

---

## 🔐 Data Protection – Encryption at Rest & In Transit

### In Transit (TLS 1.2+)

| Component                         | Encryption in Transit |
|----------------------------------|------------------------|
| Frontend (React SPA)             | CloudFront HTTPS       |
| API Gateway                      | HTTPS-only             |
| EKS Services                     | TLS ingress + service mesh (future) |
| RDS (PostgreSQL)                 | SSL enforced           |
| GitHub ↔ CodeBuild               | HTTPS                  |
| S3 Buckets                       | HTTPS enforced via bucket policies |

### At Rest (AES-256)

| Resource                    | Encryption at Rest        |
|----------------------------|----------------------------|
| EBS Volumes (EKS nodes)     | AWS-managed or CMK         |
| PostgreSQL RDS              | Default encryption (CMK optional) |
| S3 Buckets                  | SSE-S3 or SSE-KMS          |
| CloudWatch Logs             | Encrypted with KMS         |
| ECR                         | Encrypted by default       |
| CodeBuild Artifacts         | Encrypted via S3/KMS       |
| Secrets Manager / SSM       | Encrypted with CMK         |

### KMS Strategy

- Default AWS-managed keys initially
- Move to **CMKs** as IAM scopes grow (e.g., contractors, environments)
- Key rotation enabled

---

## 📈 High-Level Architecture Diagram

```mermaid
graph TB
API_Gateway[API Gateway] -->|HTTPS| ALB[ALB]
ALB -->|HTTPS| React_Frontend["React SPA (CloudFront)"]
EKS[Managed EKS Cluster] --> Backend_Services[Backend Services]
Backend_Services -->|DB Connection| PostgreSQL[RDS PostgreSQL]
Backend_Services -->|Private API| ECR[Amazon ECR]
CloudTrail[CloudTrail Logs] --> S3[CloudWatch & S3 Logs]
CloudWatch --> CloudWatch_Logs[CloudWatch Logs]
WAF[WAF] --> API_Gateway
React_Frontend -->|API Calls| API_Gateway
Backend_Services --> ECR
API_Gateway -.->|CloudWatch| CloudWatch_Logs
EKS -.->|Logs| CloudWatch_Logs
subgraph Public_Subnet
  API_Gateway
  ALB
  React_Frontend
end
subgraph Private_Subnet
  EKS
  Backend_Services
  PostgreSQL
  ECR
end
style Public_Subnet fill:#f0f0f0
style Private_Subnet fill:#e0e0e0

