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
    %% External Users with Correct Traffic Flow
    Users((Internet Users)) -->|Static Assets<br/>HTTPS| CloudFront[CloudFront CDN]
    Users -->|API Requests<br/>HTTPS| WAF[AWS WAF]
    
    %% Frontend Layer
    CloudFront -->|Origin| S3[S3 Bucket<br/>React SPA]
    
    %% API Layer with WAF Protection - Corrected Flow
    WAF -->|Protected Traffic| API_Gateway[API Gateway]
    API_Gateway -->|HTTPS| ALB[Application Load Balancer]
    
    %% Compute Layer
    ALB -->|HTTPS| EKS[Amazon EKS Cluster]
    
    subgraph EKS_Cluster[EKS Cluster - Private Subnets]
        Backend_Services[Backend Services<br/>Python/Flask APIs]
        Karpenter[Karpenter<br/>Auto Scaling]
        Monitoring[Prometheus/Grafana<br/>Monitoring]
    end
    
    %% Database Layer
    Backend_Services -->|SSL| RDS[(Amazon RDS<br/>PostgreSQL<br/>Multi-AZ)]
    
    %% CI/CD Pipeline
    GitHub[GitHub Repo] -->|Webhooks| CodePipeline[AWS CodePipeline]
    CodePipeline -->|Build| CodeBuild[AWS CodeBuild]
    CodeBuild -->|Push Images| ECR[Amazon ECR]
    CodeBuild -->|Deploy| EKS
    
    %% Security & Monitoring
    CloudTrail[CloudTrail] -->|Logs| CloudWatch[CloudWatch]
    VPC_Flow[VPC Flow Logs] -->|Logs| CloudWatch
    EKS -->|Logs| CloudWatch
    RDS -->|Logs| CloudWatch
    CloudWatch -->|Alerts| SNS[SNS Notifications]
    
    %% Secrets Management
    Backend_Services -->|Fetch Secrets| SecretsManager[AWS Secrets Manager]
    
    %% Network Boundaries
    subgraph Public_Subnets[Public Subnets]
        ALB
        NAT[NAT Gateway]
    end
    
    subgraph Private_Subnets[Private Subnets]
        EKS_Cluster
        RDS
    end
    
    %% Egress Traffic
    EKS_Cluster -->|Outbound| NAT
    NAT -->|Outbound| Internet((Internet))
    
    %% Style
    classDef aws fill:#FF9900,stroke:#232F3E,color:white;
    classDef network fill:#7AA5D2,stroke:#2C5282,color:white;
    classDef database fill:#3B48CC,stroke:#232F3E,color:white;
    classDef security fill:#D13212,stroke:#232F3E,color:white;
    
    class CloudFront,S3,API_Gateway,ALB,EKS,RDS,CodePipeline,CodeBuild,ECR,CloudTrail,CloudWatch,SNS,SecretsManager aws;
    class Public_Subnets,Private_Subnets,NAT network;
    class RDS database;
    class WAF,VPC_Flow security;


