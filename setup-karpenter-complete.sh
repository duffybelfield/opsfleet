#!/bin/bash
set -e

# Check for required CLI tools
echo "Checking for required CLI tools..."

check_command() {
  if ! command -v $1 &> /dev/null; then
    echo "Error: $1 is required but not installed. Please install $1 and try again."
    exit 1
  else
    echo "✓ $1 is installed"
  fi
}

check_command aws
check_command kubectl
check_command helm
check_command eksctl

# Verify AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
  echo "Error: AWS CLI is not configured with valid credentials."
  echo "Please run 'aws configure' or set the AWS_PROFILE environment variable."
  exit 1
else
  echo "✓ AWS CLI is configured with valid credentials"
fi

# Set environment variables for Karpenter installation
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.4.0"
export K8S_VERSION="1.31"

# AWS environment variables
export AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
export CLUSTER_NAME="opsfleet-example" # Must match the name in variables.tf
export AWS_DEFAULT_REGION="eu-west-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Get the correct AMI version from SSM parameter store
export AMI_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value | xargs aws ec2 describe-images --query 'Images[0].Name' --image-ids | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"
echo "Using AMI version: ${AMI_VERSION}"

echo "Setting up Karpenter for cluster: ${CLUSTER_NAME}"

echo "All required tools are installed and configured."
echo ""

# Apply Terraform infrastructure
echo "Applying Terraform infrastructure..."
terraform apply -auto-approve

aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)

# Verify kubectl can connect to the cluster
if ! kubectl get nodes &> /dev/null; then
  echo "Error: kubectl cannot connect to the Kubernetes cluster."
  echo "Please ensure your kubeconfig is correctly set up."
  exit 1
else
  echo "✓ kubectl is connected to the cluster"
fi

# Get cluster endpoint
export CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)
echo "Cluster endpoint: ${CLUSTER_ENDPOINT}"

# Get node group name from Terraform output and extract just the part after the colon
export NODE_GROUP_ID=$(terraform output -raw node_group_name)
export NODE_GROUP_NAME=$(echo "${NODE_GROUP_ID}" | cut -d':' -f2)
echo "Node group name: ${NODE_GROUP_NAME}"

# Get node group role ARN
export NODE_GROUP_ROLE_ARN=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODE_GROUP_NAME}" --query "nodegroup.nodeRole" --output text)
echo "Node group role ARN: ${NODE_GROUP_ROLE_ARN}"

# Check if the spot service linked role already exists
echo "Checking if the spot service linked role already exists..."
if aws iam get-role --role-name AWSServiceRoleForEC2Spot &> /dev/null; then
  echo "Spot service linked role already exists, skipping creation."
else
  echo "Creating spot service linked role..."
  aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
fi

# Create IAM role for Karpenter controller
echo "Creating IAM role for Karpenter controller..."
OIDC_ISSUER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo "$OIDC_ISSUER" | cut -d '/' -f 5)
CONTROLLER_ROLE_NAME="${CLUSTER_NAME}-karpenter"

if ! aws iam get-role --role-name "${CONTROLLER_ROLE_NAME}" &> /dev/null; then
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
            "oidc.eks.'"${AWS_DEFAULT_REGION}"'.amazonaws.com/id/'"${OIDC_ID}"':sub": "system:serviceaccount:'"${KARPENTER_NAMESPACE}"':karpenter-manual"
          }
        }
      }
    ]
  }'
  echo "Created IAM role: ${CONTROLLER_ROLE_NAME}"
else
  # Update the trust relationship
  aws iam update-assume-role-policy --role-name "${CONTROLLER_ROLE_NAME}" --policy-document '{
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
            "oidc.eks.'"${AWS_DEFAULT_REGION}"'.amazonaws.com/id/'"${OIDC_ID}"':sub": "system:serviceaccount:'"${KARPENTER_NAMESPACE}"':karpenter-manual"
          }
        }
      }
    ]
  }'
  echo "Updated trust relationship for IAM role: ${CONTROLLER_ROLE_NAME}"
fi

# Get the Karpenter controller policy ARN from Terraform output
POLICY_ARN=$(terraform output -raw karpenter_controller_policy_arn)
echo "Using Karpenter controller policy ARN: ${POLICY_ARN}"

# Attach policy to the controller role
echo "Attaching policy to the controller role..."
aws iam attach-role-policy --role-name "${CONTROLLER_ROLE_NAME}" --policy-arn "${POLICY_ARN}"

# Install Karpenter using Helm
echo "Installing Karpenter Helm chart..."
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

# Patch the karpenter-manual service account to enable token mounting
echo "Patching karpenter-manual service account to enable token mounting..."
kubectl patch serviceaccount -n "${KARPENTER_NAMESPACE}" karpenter-manual -p '{"automountServiceAccountToken": true}'

# Create a token for the karpenter-manual service account
echo "Creating a token for the karpenter-manual service account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-manual-token
  namespace: ${KARPENTER_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: karpenter-manual
type: kubernetes.io/service-account-token
EOF

# Update the aws-auth ConfigMap
echo "Updating aws-auth ConfigMap..."
sed -e "s|\${NODE_GROUP_ROLE_ARN}|${NODE_GROUP_ROLE_ARN}|g" \
    -e "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" \
    -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
    karpenter-resources/aws-auth-patch.yaml > aws-auth-patch-resolved.yaml

kubectl apply -f aws-auth-patch-resolved.yaml

# Apply Karpenter global settings
echo "Applying Karpenter global settings..."
sed -e "s|\${CLUSTER_ENDPOINT}|${CLUSTER_ENDPOINT}|g" \
    -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
    karpenter-resources/global-settings.yaml > global-settings-resolved.yaml

kubectl apply -f global-settings-resolved.yaml

# Apply EC2NodeClass
echo "Applying EC2NodeClass..."
sed -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
    -e "s|al2023@v20250410|al2023@${AMI_VERSION}|g" \
    karpenter-resources/ec2nodeclass.yaml > ec2nodeclass-resolved.yaml

kubectl apply -f ec2nodeclass-resolved.yaml

# Apply NodePool
echo "Applying NodePool..."
kubectl apply -f karpenter-resources/nodepool.yaml

# Wait for Karpenter to be ready
echo "Waiting for Karpenter to be ready..."
kubectl wait --for=condition=Ready nodepool/default --timeout=60s || true

echo "Karpenter setup complete!"
echo ""
echo "To test Karpenter, deploy the test deployment with:"
echo "kubectl apply -f karpenter-resources/test-deployment.yaml"
echo ""
echo "To monitor Karpenter, run:"
echo "kubectl logs -f -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter -c controller"
echo ""
echo "To clean up, run:"
echo "kubectl delete -f karpenter-resources/test-deployment.yaml"
echo "kubectl delete nodepool default"
echo "kubectl delete ec2nodeclass default"
echo "kubectl delete -f global-settings-resolved.yaml"
echo "helm uninstall karpenter-manual -n ${KARPENTER_NAMESPACE}"
echo "terraform destroy -auto-approve"
