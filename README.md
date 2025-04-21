# EKS Cluster with Karpenter

This repository contains Terraform configuration for deploying an EKS cluster with Karpenter for node provisioning.

## Prerequisites

### Required CLI Tools

The following CLI tools are required to deploy and manage the EKS cluster with Karpenter:

| Tool | Version | Installation Instructions |
|------|---------|---------------------------|
| Terraform | >= 1.0.0 | [Terraform Installation](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli) |
| AWS CLI | >= 2.0.0 | [AWS CLI Installation](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| kubectl | >= 1.24.0 | [kubectl Installation](https://kubernetes.io/docs/tasks/tools/) |
| Helm | >= 3.8.0 | [Helm Installation](https://helm.sh/docs/intro/install/) |
| eksctl | >= 0.135.0 | [eksctl Installation](https://eksctl.io/installation/) |

Make sure to configure the AWS CLI with appropriate credentials:

```bash
aws configure
# Or use a named profile
aws configure --profile your-profile-name
```

If using a named profile, you can set it as the default for your session:

```bash
export AWS_PROFILE=your-profile-name
```

## Deployment Steps

### Option 1: Automated Setup with setup-karpenter-complete.sh

There is a comprehensive setup script that automates the entire process of deploying the EKS cluster and setting up Karpenter:

```bash
# Make the setup script executable
chmod +x setup-karpenter-complete.sh

# Run the setup script
./setup-karpenter-complete.sh
```

The `setup-karpenter-complete.sh` script will:

1. Check for required CLI tools (aws, kubectl, helm, eksctl)
2. Verify AWS CLI is configured with valid credentials
3. Set up environment variables for Karpenter installation
4. Apply Terraform to create the EKS cluster and supporting infrastructure
5. Update kubeconfig to connect to the newly created cluster
6. Verify kubectl can connect to the cluster
7. Create IAM roles and policies for Karpenter
8. Install Karpenter using Helm
9. Apply Karpenter resources (EC2NodeClass, NodePool, global settings)

This is the recommended approach for setting up the cluster as it ensures all steps are performed in the correct order.

### Option 2: Manual Setup

If you prefer to set up the cluster manually, you can follow these steps:

#### 1. Deploy the EKS Cluster with Terraform

```bash
# Initialize Terraform
terraform init -upgrade

# Preview changes
terraform plan

# Apply changes
terraform apply
```

#### 2. Update kubeconfig to connect to the cluster

```bash
aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)
```

#### 3. Install Karpenter Manually

Following the [official Karpenter getting started guide](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/).

#### Set Environment Variables

```bash
# Set environment variables for Karpenter installation
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.4.0"
export K8S_VERSION="1.31"

# AWS environment variables
export AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
export CLUSTER_NAME="opsfleet-example" # Must match the name in variables.tf
export AWS_DEFAULT_REGION="eu-west-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

#### IAM Resources for Karpenter

The required IAM policy for Karpenter is included in the Terraform configuration in `karpenter-infrastructure.tf`. This policy provides the necessary permissions for Karpenter to:

- Create and manage EC2 instances
- Pass IAM roles to instances
- Access SSM parameters for AMI information
- Get pricing information
- Handle spot instance interruptions
- Access ECR repositories

When you run `terraform apply`, this policy will be created automatically, and its ARN will be available as a Terraform output.

You'll need to create an IAM role for Karpenter and attach the policy:

```bash
# Get the OIDC provider ID
OIDC_ISSUER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo "$OIDC_ISSUER" | cut -d '/' -f 5)
CONTROLLER_ROLE_NAME="${CLUSTER_NAME}-karpenter"

# Create the IAM role with the appropriate trust relationship
aws iam create-role --role-name "${CONTROLLER_ROLE_NAME}" --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::'"${AWS_ACCOUNT_ID}"':oidc-provider/oidc.eks.'"${AWS_DEFAULT_REGION}"'.amazonaws.com/id/'"${OIDC_ID}"'"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.'"${AWS_DEFAULT_REGION}"'.amazonaws.com/id/'"${OIDC_ID}"':sub": "system:serviceaccount:'"${KARPENTER_NAMESPACE}"':karpenter"
        }
      }
    }
  ]
}'

# Get the policy ARN from Terraform output
POLICY_ARN=$(terraform output -raw karpenter_controller_policy_arn)

# Attach the policy to the role
aws iam attach-role-policy --role-name "${CONTROLLER_ROLE_NAME}" --policy-arn "${POLICY_ARN}"

# Create the spot service linked role if it doesn't exist
if aws iam get-role --role-name AWSServiceRoleForEC2Spot &> /dev/null; then
  echo "Spot service linked role already exists, skipping creation."
else
  echo "Creating spot service linked role..."
  aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
fi
```

> **Note**: The service-linked role for EC2 Spot instances (`AWSServiceRoleForEC2Spot`) only needs to be created once per AWS account. If it already exists, the script will detect this and skip the creation step.

#### Install Karpenter Helm Chart

Install Karpenter using the OCI registry as specified in the [official guide](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/):

```bash
# Install Karpenter using OCI registry
helm upgrade --install karpenter-manual oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CONTROLLER_ROLE_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

#### Apply Karpenter Resources

Apply the Karpenter resources from the `karpenter-resources` directory:

```bash
# Apply global settings
kubectl apply -f karpenter-resources/global-settings.yaml

# Apply EC2NodeClass
kubectl apply -f karpenter-resources/ec2nodeclass.yaml

# Apply NodePool
kubectl apply -f karpenter-resources/nodepool.yaml
```

## Testing Karpenter with Multi-Architecture Support

There is a test deployment that will provision both amd64 and arm64 nodes:

```bash
# Apply the test deployment
kubectl apply -f karpenter-resources/test-deployment.yaml

# Watch Karpenter logs
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter-manual -c controller
```

This will create two deployments:
- `inflate-amd64`: Requests amd64 (x86_64) nodes
- `inflate-arm64`: Requests arm64 nodes

Karpenter will automatically provision the appropriate instance types based on the architecture requirements.

### Verifying the Deployment

You can verify that Karpenter has provisioned the correct nodes and scheduled the pods on them:

```bash
# Check the nodes and their architecture
kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture

# Check the pods and which nodes they're running on
kubectl get pods -o wide
```

You should see:
- One or more amd64 nodes running the amd64 pods
- One or more arm64 nodes running the arm64 pods

This confirms that Karpenter is correctly provisioning nodes based on the architecture requirements of the pods.

### Project Structure

The project consists of the following key files:

| File/Directory | Description |
|----------------|-------------|
| `main.tf` | Main Terraform configuration for the EKS cluster |
| `karpenter-infrastructure.tf` | Terraform configuration for Karpenter infrastructure (IAM, SQS, etc.) |
| `outputs.tf` | Terraform outputs for the EKS cluster and Karpenter resources |
| `variables.tf` | Terraform variables for the EKS cluster and Karpenter |
| `setup-karpenter-complete.sh` | Automated script for setting up the EKS cluster and Karpenter |
| `karpenter-resources/` | Directory containing Karpenter resource definitions |
| `karpenter-resources/ec2nodeclass.yaml` | EC2NodeClass definition for Karpenter |
| `karpenter-resources/nodepool.yaml` | NodePool definition for Karpenter |
| `karpenter-resources/global-settings.yaml` | Global settings for Karpenter |
| `karpenter-resources/aws-auth-patch.yaml` | Patch for aws-auth ConfigMap |
| `karpenter-resources/test-deployment.yaml` | Test deployment for Karpenter |

## Troubleshooting

### Common Issues

#### Service-Linked Role Already Exists

If you encounter an error like `An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account`:

```bash
# This is not actually an error - it just means the role already exists
# The script now checks if the role exists before trying to create it
```

#### OCI Registry Authentication Issues

If you encounter authentication issues with the OCI registry:

```bash
# Logout from ECR to clear any stale credentials
helm registry logout public.ecr.aws

# If you're still having issues, you can try authenticating explicitly
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
```

#### Helm Release "cannot re-use a name that is still in use"

If you encounter an error like `Error: cannot re-use a name that is still in use`:

```bash
# Check the status of Helm releases
helm list -A

# If you don't see any releases but still get the error, check for stuck releases
helm list -A --pending
helm list -A --failed

# Remove the stuck release
helm uninstall karpenter -n kube-system
```

#### Helm Release "cannot re-use a name that is still in use"

If you encounter an error like `Error: cannot re-use a name that is still in use` when installing Karpenter with Helm:

```bash
# Check the status of Helm releases
helm list -A

# If you don't see any releases but still get the error, check for stuck releases
helm list -A --pending
helm list -A --failed

# Remove the stuck release
helm uninstall karpenter -n kube-system
```

#### IAM Role Trust Relationship Issues

If Karpenter pods are failing with authentication errors:

```bash
# Check the Karpenter pod logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller

# Verify the IAM role trust relationship
aws iam get-role --role-name ${CLUSTER_NAME}-karpenter --query 'Role.AssumeRolePolicyDocument' | jq .

# The trust relationship should include the correct OIDC provider and service account
```

#### Node Provisioning Issues

If Karpenter is not provisioning nodes:

```bash
# Check Karpenter logs for provisioning decisions
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller

# Verify the provisioner is correctly configured
kubectl get provisioner default -o yaml

# Verify the AWS node template is correctly configured
kubectl get awsnodetemplate default -o yaml

# Check if the security groups and subnets have the correct tags
aws ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" | jq .
aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" | jq .
```

## Cleanup

To clean up the resources:

```bash
# Delete the test deployments
kubectl delete -f karpenter-resources/test-deployment.yaml

# Delete Karpenter resources
kubectl delete nodepool default
kubectl delete ec2nodeclass default
kubectl delete -f karpenter-resources/global-settings.yaml

# Uninstall Karpenter
helm uninstall karpenter-manual -n kube-system

# Delete the Terraform-managed resources
terraform destroy -auto-approve
```
