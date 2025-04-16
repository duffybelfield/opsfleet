# Multi-Architecture Nginx Deployment with Karpenter

This project demonstrates how to deploy nginx on both ARM64 and AMD64 nodes in a Kubernetes cluster using Karpenter for node provisioning.

## Files Included

### Terraform Files
- **main.tf**: Main Terraform configuration for EKS and Karpenter
- **karpenter.tf**: Karpenter Helm chart and Kubernetes resources
- **providers.tf**: AWS, Helm, and Kubectl provider configuration
- **variables.tf**: Variable definitions for customizing the deployment
- **terraform.tfvars**: Default values for variables

### Kubernetes Manifests
- **nginx-deployment.yaml**: Deployment manifest with topology spread constraints to distribute pods across architectures
- **nginx-service.yaml**: LoadBalancer service to expose nginx externally
- **nginx-config.yaml**: ConfigMap with custom nginx configuration that adds architecture information in headers
- **arm64-test-pod.yaml**: Fallback option to force ARM64 node provisioning if needed

## Infrastructure Deployment

### 1. Customize the Deployment (Optional)

You can customize the deployment by modifying the `terraform.tfvars` file:

```hcl
# AWS Region
region = "eu-west-1"

# EKS Cluster Configuration
cluster_name    = null  # Will use the auto-generated name
cluster_version = "1.31"

# Node Group Configuration
node_instance_types   = ["m5.large"]
node_group_min_size   = 2
node_group_max_size   = 3
node_group_desired_size = 2

# Karpenter Configuration
karpenter_version = "1.3.3"

# VPC Configuration
vpc_cidr = "10.0.0.0/16"
```

### 2. Initialize and Apply Terraform

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

The deployment process is now fully automated! The Terraform configuration includes:

1. **Automatic Service Account Patching**: Fixes the Karpenter service account token mounting issue
2. **Correct IAM Role Trust Relationship**: Ensures the Karpenter controller can assume the IAM role
3. **EC2 Read Permissions**: Adds necessary EC2 read permissions to the Karpenter controller role
4. **Automatic Kubernetes Manifest Application**: Applies the Nginx manifests after the cluster is ready
5. **Automatic ARM64 Fallback**: Detects if ARM64 nodes are missing and applies the fallback pod

### 3. Configure kubectl (if needed)

After the infrastructure is deployed, configure kubectl to connect to the cluster:

```bash
aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)
```

## Kubernetes Deployment Process

The Kubernetes deployment process is now fully automated by Terraform! After running `terraform apply`, the following steps are performed automatically:

1. The EKS cluster and Karpenter are set up with all necessary fixes
2. kubectl is configured to connect to the cluster
3. Kubernetes manifests are applied in the correct order:
   - nginx-config.yaml (ConfigMap)
   - nginx-deployment.yaml (Deployment)
   - nginx-service.yaml (Service)
4. The deployment is monitored for a short period
5. Node and pod distribution are checked
6. If no ARM64 nodes are provisioned, the fallback pod (arm64-test-pod.yaml) is automatically applied

### Manual Deployment (if needed)

If you prefer to deploy manually or need to redeploy, you can follow these steps:

```bash
# 1. Apply the ConfigMap first
kubectl apply -f nginx-config.yaml

# 2. Apply the Deployment next
kubectl apply -f nginx-deployment.yaml

# 3. Apply the Service last
kubectl apply -f nginx-service.yaml
```

### Manual Monitoring

```bash
# Monitor pod creation
kubectl get pods -l app=nginx -w

# Check node provisioning
kubectl get nodes -L kubernetes.io/arch -w
```

### Manual Fallback (if needed)

If Karpenter doesn't automatically provision ARM64 nodes and the automatic fallback didn't trigger:

```bash
kubectl apply -f arm64-test-pod.yaml
```

This will force Karpenter to provision an ARM64 node, which should then allow the nginx pods to be properly distributed across both architectures.

### 4. Verify the Deployment

```bash
# Check pod distribution
kubectl get pods -l app=nginx -o wide

# Check node architectures
kubectl get nodes -L kubernetes.io/arch

# Test the service
export NGINX_IP=$(kubectl get service nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in {1..10}; do curl -s -I http://$NGINX_IP | grep X-Node-Architecture; done
```

## Cleanup

When you're done with the deployment, you can clean up all resources:

```bash
# Delete Kubernetes resources
kubectl delete -f nginx-service.yaml -f nginx-deployment.yaml -f nginx-config.yaml
kubectl delete -f arm64-test-pod.yaml # if applied

# Destroy infrastructure
terraform destroy
```

## Key Features

- Uses topology spread constraints with `whenUnsatisfiable: DoNotSchedule` to enforce distribution across architectures
- Custom nginx configuration adds X-Node-Architecture header to responses
- Fallback mechanism to guarantee ARM64 node provisioning if needed
- Fully automated deployment process with built-in fixes for known issues

## Known Issues and Fixes

This project includes fixes for several known issues with Karpenter:

1. **Service Account Token Mounting**
   - **Issue**: The Karpenter Helm chart sets `automountServiceAccountToken: false` by default
   - **Fix**: Added a null_resource to patch the service account after installation

2. **IAM Role Trust Relationship**
   - **Issue**: The trust relationship is configured for the wrong namespace by default
   - **Fix**: Added `irsa_assume_role_condition_test = "StringEquals"` to fix the trust relationship

3. **Missing EC2 Permissions**
   - **Issue**: The Karpenter controller lacks necessary EC2 read permissions
   - **Fix**: Added the AmazonEC2ReadOnlyAccess policy to the controller role

4. **Helm Chart Settings Structure**
   - **Issue**: The settings structure needs to match Karpenter 1.3.3 requirements
   - **Fix**: Ensured `clusterName` and `clusterEndpoint` are at the top level of settings

For more details on these issues and fixes, see [fixes.md](fixes.md).

## Detailed Documentation

For more detailed information, see [nginx-deployment.md](nginx-deployment.md).