# Karpenter Setup Guide

This guide explains how to set up Karpenter on an EKS cluster using the provided files.

## Prerequisites

- AWS CLI
- kubectl
- Helm
- eksctl
- Terraform

## File Structure

- `karpenter-infrastructure.tf`: Terraform file for Karpenter infrastructure (IAM roles, policies, SQS queue, EventBridge rules)
- `karpenter-resources/`: Directory containing Kubernetes resources for Karpenter
  - `ec2nodeclass.yaml`: EC2NodeClass configuration
  - `nodepool.yaml`: NodePool configuration
  - `global-settings.yaml`: Global settings ConfigMap
  - `aws-auth-patch.yaml`: aws-auth ConfigMap patch
  - `test-deployment.yaml`: Test deployment to verify Karpenter works
- `setup-karpenter-complete.sh`: Script to set up Karpenter

## Setup Instructions

1. Make sure your AWS CLI is configured with the correct credentials and region.
2. Make sure your kubectl is configured to connect to your EKS cluster.
3. Run the setup script:

```bash
./setup-karpenter-complete.sh
```

The script will:
- Apply Terraform infrastructure
- Create IAM roles and policies
- Install Karpenter using Helm
- Apply Kubernetes resources
- Provide instructions for testing and cleanup

## Testing Karpenter

To test Karpenter, deploy the test deployment:

```bash
kubectl apply -f karpenter-resources/test-deployment.yaml
```

This will create two deployments:
- `inflate-amd64`: Requests amd64 nodes
- `inflate-arm64`: Requests arm64 nodes

Karpenter should automatically provision the required nodes.

## Monitoring Karpenter

To monitor Karpenter logs:

```bash
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter -c controller
```

## Cleanup

To clean up:

```bash
kubectl delete -f karpenter-resources/test-deployment.yaml
kubectl delete nodepool default
kubectl delete ec2nodeclass default
kubectl delete -f global-settings-resolved.yaml
helm uninstall karpenter-manual -n kube-system
terraform destroy -auto-approve
```

## Troubleshooting

If you encounter issues with Karpenter:

1. Check the Karpenter logs:
```bash
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter -c controller
```

2. Verify the EC2NodeClass is using the correct AMI alias:
```bash
kubectl describe ec2nodeclass default
```

3. Verify the NodePool is ready:
```bash
kubectl describe nodepool default
```

4. Verify the aws-auth ConfigMap includes the Karpenter node role:
```bash
kubectl describe configmap -n kube-system aws-auth
```

5. Verify the global settings ConfigMap:
```bash
kubectl describe configmap -n kube-system karpenter-global-settings