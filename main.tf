data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  name   = var.cluster_name != null ? var.cluster_name : "ex-${basename(path.cwd)}"
  region = var.region

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.3"
  cluster_name    = local.name
  cluster_version = var.cluster_version

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    karpenter = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = var.node_instance_types

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

################################################################################
# Karpenter
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.8.3"
  
  cluster_name           = module.eks.cluster_name
  irsa_oidc_provider_arn = module.eks.oidc_provider_arn
  
  # Enable instance profile creation
  create_instance_profile = true
  
  # Enable IRSA for Karpenter
  enable_irsa = true
  enable_pod_identity = false

  # Enable spot termination handling
  enable_spot_termination = true
  
  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix = false
  node_iam_role_name = local.name
  
  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  
  tags = local.tags
}


module "karpenter_disabled" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"

  create = false
}

# Create a custom policy for Karpenter with specific EC2 permissions
resource "aws_iam_policy" "karpenter_ec2_permissions" {
  name        = "${local.name}-karpenter-ec2-permissions"
  description = "Custom policy for Karpenter EC2 API access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstances",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "pricing:GetProducts",
          "iam:PassRole",
          "iam:GetInstanceProfile",
          "ecs:DescribeInstanceTypes"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

# Update the aws_iam_role_policy_attachment.karpenter_ec2_read_only resource
resource "aws_iam_role_policy_attachment" "karpenter_ec2_read_only" {
  # This policy is no longer needed as we're using our custom role
  count      = 0
  role       = "unused"
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
  
  depends_on = [
    module.karpenter
  ]
}

# Attach the custom policy to the Karpenter role
resource "aws_iam_role_policy_attachment" "karpenter_ec2_permissions" {
  # This policy is no longer needed as we're using our custom role
  count      = 0
  role       = "unused"
  policy_arn = aws_iam_policy.karpenter_ec2_permissions.arn
}

# Create a dedicated IAM role for Karpenter with the correct namespace in the trust relationship
resource "aws_iam_role" "karpenter_controller" {
  name = "KarpenterController-${local.name}"
  
  # Use the namespace from the Helm chart (kube-system)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:karpenter"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
  
  tags = local.tags
}

# Attach the EC2 permissions policy to the new role
resource "aws_iam_role_policy_attachment" "karpenter_controller_ec2_permissions" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_ec2_permissions.arn
}

# Attach the EC2 read-only policy to the new role
resource "aws_iam_role_policy_attachment" "karpenter_controller_ec2_read_only" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

resource "null_resource" "apply_kubernetes_manifests" {
  depends_on = [
    module.eks,
    module.karpenter,
    null_resource.wait_for_cluster,
    null_resource.karpenter_serviceaccount_patch,
    aws_iam_role.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_permissions,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_read_only,
    kubectl_manifest.karpenter_node_class,
    kubectl_manifest.karpenter_node_pool
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      # Configure kubectl
      AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # Wait for Karpenter to be ready
      echo "Waiting for Karpenter to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n kube-system || true
      
      # Apply all Kubernetes manifest files
      echo "Applying Kubernetes manifest files..."
      %{for manifest_file in var.k8s_manifest_files~}
      echo "Applying ${manifest_file}..."
      kubectl apply -f ${manifest_file}
      %{endfor~}
      
      # Comprehensive debugging for ARM64 provisioning issues
      echo "============= STARTING COMPREHENSIVE DEBUGGING ============="
      
      # 0. Check and fix NodePool status
      echo "0. Checking and fixing NodePool status..."
      kubectl get nodepool
      kubectl describe nodepool default
      
      # Try to fix the NodePool by recreating it
      echo "Recreating the NodePool..."
      kubectl delete nodepool default || true
      sleep 10
      kubectl apply -f - <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: "kubernetes.io/arch"
          operator: In
          values: ["arm64", "amd64"]
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["t", "c", "m", "r"]
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["2", "4", "8"]
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
  limits:
    cpu: 1000
EOF
      
      # 1. Check Karpenter deployment status
      echo "1. Checking Karpenter deployment status..."
      kubectl get deployment -n kube-system karpenter -o wide
      
      # 2. Check Karpenter logs
      echo "2. Checking Karpenter logs for provisioning requests..."
      echo "Full Karpenter logs:"
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=200
      
      echo "Filtered logs for provisioning:"
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i provision || true
      
      echo "Filtered logs for ARM64:"
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i arm64 || true
      
      echo "Filtered logs for errors:"
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i error || true
      
      echo "Filtered logs for warnings:"
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i warn || true
      
      # 3. Check NodePool and EC2NodeClass configuration
      echo "3. Checking NodePool and EC2NodeClass configuration..."
      kubectl get nodepool -o yaml
      kubectl get ec2nodeclass -o yaml
      kubectl describe ec2nodeclass default
      
      # Check EC2NodeClass status in detail
      echo "Checking EC2NodeClass status in detail..."
      kubectl get ec2nodeclass default -o yaml
      kubectl describe ec2nodeclass default
      
      # Check if the IAM role exists and matches the one in EC2NodeClass
      echo "Checking if the IAM role exists and matches the one in EC2NodeClass..."
      EC2_ROLE=$(kubectl get ec2nodeclass default -o jsonpath='{.spec.role}')
      echo "Role name in EC2NodeClass: $EC2_ROLE"
      echo "Expected role name: ${local.name}"
      
      if [ "$EC2_ROLE" != "${local.name}" ]; then
        echo "WARNING: Role name mismatch between EC2NodeClass ($EC2_ROLE) and expected role (${local.name})"
      fi
      
      AWS_PROFILE=${var.aws_profile} aws iam get-role --role-name ${local.name} || echo "Role ${local.name} does not exist"
      
      if [ "$EC2_ROLE" != "${local.name}" ]; then
        AWS_PROFILE=${var.aws_profile} aws iam get-role --role-name $EC2_ROLE || echo "Role $EC2_ROLE does not exist"
      fi
      
      # Check if the instance profile exists for the role
      echo "Checking if the instance profile exists for the role..."
      AWS_PROFILE=${var.aws_profile} aws iam list-instance-profiles-for-role --role-name ${local.name} || echo "No instance profile found for role ${local.name}"
      
      if [ "$EC2_ROLE" != "${local.name}" ]; then
        AWS_PROFILE=${var.aws_profile} aws iam list-instance-profiles-for-role --role-name $EC2_ROLE || echo "No instance profile found for role $EC2_ROLE"
      fi
      
      # Check the instance profile name from Karpenter module
      echo "Instance profile name from Karpenter module: ${module.karpenter.instance_profile_name}"
      
      # Check if the EC2NodeClass is using the correct instance profile name
      echo "Checking if the EC2NodeClass is using the correct instance profile name..."
      EC2_INSTANCE_PROFILE=$(kubectl get ec2nodeclass default -o jsonpath='{.spec.instanceProfile}' 2>/dev/null || echo "Not set")
      echo "Instance profile in EC2NodeClass: $EC2_INSTANCE_PROFILE"
      
      if [ "$EC2_INSTANCE_PROFILE" = "Not set" ]; then
        echo "WARNING: instanceProfile is not set in EC2NodeClass. It should be set to ${module.karpenter.instance_profile_name}"
        
        # Try to update the EC2NodeClass to include the instance profile
        echo "Updating EC2NodeClass to include the instance profile..."
        kubectl patch ec2nodeclass default --type=merge -p "{\"spec\":{\"instanceProfile\":\"${module.karpenter.instance_profile_name}\"}}" || true
      elif [ "$EC2_INSTANCE_PROFILE" != "${module.karpenter.instance_profile_name}" ]; then
        echo "WARNING: Instance profile mismatch between EC2NodeClass ($EC2_INSTANCE_PROFILE) and Karpenter module (${module.karpenter.instance_profile_name})"
        
        # Try to update the EC2NodeClass to use the correct instance profile
        echo "Updating EC2NodeClass to use the correct instance profile..."
        kubectl patch ec2nodeclass default --type=merge -p "{\"spec\":{\"instanceProfile\":\"${module.karpenter.instance_profile_name}\"}}" || true
      fi
      
      # Check if the subnets with the discovery tag exist
      echo "Checking if subnets with the discovery tag exist..."
      AWS_PROFILE=${var.aws_profile} aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${module.eks.cluster_name}" || echo "No subnets found with the discovery tag"
      
      # Check if the security groups with the discovery tag exist
      echo "Checking if security groups with the discovery tag exist..."
      AWS_PROFILE=${var.aws_profile} aws ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${module.eks.cluster_name}" || echo "No security groups found with the discovery tag"
      
      # Try to fix the EC2NodeClass by recreating it with more detailed configuration
      echo "Recreating the EC2NodeClass with more detailed configuration..."
      kubectl delete ec2nodeclass default || true
      sleep 10
      
      # Get the actual subnet IDs and security group IDs
      SUBNET_IDS=$(AWS_PROFILE=${var.aws_profile} aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${module.eks.cluster_name}" --query "Subnets[*].SubnetId" --output text | tr '\t' ',')
      SG_IDS=$(AWS_PROFILE=${var.aws_profile} aws ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${module.eks.cluster_name}" --query "SecurityGroups[*].GroupId" --output text | tr '\t' ',')
      
      # Create the EC2NodeClass with explicit subnet and security group IDs if available
      if [ -n "$SUBNET_IDS" ] && [ -n "$SG_IDS" ]; then
        echo "Creating EC2NodeClass with explicit subnet IDs: $SUBNET_IDS and security group IDs: $SG_IDS"
        kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  instanceProfile: ${module.karpenter.instance_profile_name}
  subnetSelector:
    aws-ids: $SUBNET_IDS
  securityGroupSelector:
    aws-ids: $SG_IDS
  tags:
    karpenter.sh/discovery: ${module.eks.cluster_name}
EOF
      else
        echo "Creating EC2NodeClass with tag selectors"
        kubectl apply -f - <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: bottlerocket@latest
  instanceProfile: ${module.karpenter.instance_profile_name}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  tags:
    karpenter.sh/discovery: ${module.eks.cluster_name}
EOF
      fi
      
      # 4. Check ARM64 test pod status
      echo "4. Checking ARM64 test pod status..."
      kubectl describe pod arm64-test -n kube-system
      
      # 5. Check if there are any events related to provisioning
      echo "5. Checking cluster events related to provisioning..."
      kubectl get events -n kube-system | grep -i provision || true
      kubectl get events -n kube-system | grep -i arm64 || true
      
      # 6. Check if there are any pending pods
      echo "6. Checking for pending pods..."
      kubectl get pods -A | grep Pending || true
      
      # 7. Check available instance types in the region
      echo "7. Checking available ARM64 instance types in the region..."
      AWS_PROFILE=${var.aws_profile} aws ec2 describe-instance-types --filters "Name=processor-info.supported-architecture,Values=arm64" --query "InstanceTypes[*].InstanceType" --output text | tr '\t' '\n' | sort
      
      # 8. Check if there are any capacity issues in the region
      echo "8. Checking for capacity issues in the region..."
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i "capacity" || true
      kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100 | grep -i "insufficient" || true
      
      # 8.5 Check IAM role and permissions
      echo "8.5. Checking IAM role and permissions for Karpenter..."
      echo "Karpenter service account:"
      kubectl get serviceaccount -n kube-system karpenter -o yaml
      
      echo "Checking IAM role ARN annotation:"
      kubectl get serviceaccount -n kube-system karpenter -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
      echo ""
      
      echo "Checking if Karpenter can assume the role:"
      ROLE_ARN=$(kubectl get serviceaccount -n kube-system karpenter -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
      if [ -n "$ROLE_ARN" ]; then
        AWS_PROFILE=${var.aws_profile} aws sts get-caller-identity
        echo "Checking role policies:"
        ROLE_NAME=$(echo $ROLE_ARN | cut -d'/' -f2)
        AWS_PROFILE=${var.aws_profile} aws iam list-attached-role-policies --role-name $ROLE_NAME || true
        
        # Check the trust relationship
        echo "Checking trust relationship for role $ROLE_NAME:"
        AWS_PROFILE=${var.aws_profile} aws iam get-role --role-name $ROLE_NAME --query "Role.AssumeRolePolicyDocument" || true
        
        # Check the EC2 permissions in detail
        echo "Checking EC2 permissions in detail:"
        for policy in $(AWS_PROFILE=${var.aws_profile} aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[*].PolicyArn" --output text); do
          echo "Policy: $policy"
          AWS_PROFILE=${var.aws_profile} aws iam get-policy-version --policy-arn $policy --version-id $(AWS_PROFILE=${var.aws_profile} aws iam get-policy --policy-arn $policy --query "Policy.DefaultVersionId" --output text) --query "PolicyVersion.Document" || true
        done
        
        # Check if the node IAM role exists and has the necessary permissions
        echo "Checking node IAM role ${local.name}:"
        AWS_PROFILE=${var.aws_profile} aws iam get-role --role-name ${local.name} || echo "Node role does not exist"
        AWS_PROFILE=${var.aws_profile} aws iam list-attached-role-policies --role-name ${local.name} || echo "Cannot list policies for node role"
      else
        echo "No role ARN found on the service account"
      fi
      
      # 9. Check Karpenter Helm release configuration
      echo "9. Checking Karpenter Helm release configuration..."
      helm get values -n kube-system karpenter || true
      helm get manifest -n kube-system karpenter | grep -A 20 "kind: Deployment" || true
      
      # 10. Try to force provisioning by scaling the deployment
      echo "10. Trying to force ARM64 provisioning by creating more pods..."
      cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: arm64-test-deployment
  namespace: kube-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app: arm64-test-deployment
  template:
    metadata:
      labels:
        app: arm64-test-deployment
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
      - name: nginx
        image: nginx:latest
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1
            memory: 1Gi
EOF
      
      # Wait for ARM64 node to be provisioned with increased timeout
      echo "Waiting for ARM64 node to be provisioned..."
      for i in {1..20}; do
        if kubectl get nodes -l kubernetes.io/arch=arm64 | grep -q arm64; then
          echo "ARM64 node provisioned successfully!"
          break
        fi
        
        # Debug Karpenter provisioning every iteration
        echo "Iteration $i: Checking Karpenter logs for ARM64 provisioning..."
        kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep -i arm64 || true
        kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep -i provision || true
        
        # Check pending pods
        echo "Iteration $i: Checking pending pods..."
        kubectl get pods -A | grep Pending || true
        
        echo "Waiting for ARM64 node... attempt $i/20"
        sleep 30
      done
      
      # Wait for the ARM64 node to be ready
      echo "Waiting for ARM64 node to be ready..."
      kubectl wait --for=condition=ready --selector=kubernetes.io/arch=arm64 --timeout=600s node || true
      
      # If ARM64 node is still not provisioned, try to check if ARM64 instances are available in the region
      if ! kubectl get nodes -l kubernetes.io/arch=arm64 | grep -q arm64; then
        echo "ARM64 node not provisioned. Checking if ARM64 instances are available in the region..."
        
        # Check available ARM64 instance types in the region
        echo "Available ARM64 instance types in the region:"
        AWS_PROFILE=${var.aws_profile} aws ec2 describe-instance-types --filters "Name=processor-info.supported-architecture,Values=arm64" --query "InstanceTypes[*].InstanceType" --output text | tr '\t' '\n' | sort
        
        # Check if there are any capacity issues in the region
        echo "Checking for capacity issues in the region..."
        AWS_PROFILE=${var.aws_profile} aws ec2 describe-spot-price-history --instance-types t4g.small --product-description "Linux/UNIX" --start-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") --region ${var.region} --query "SpotPriceHistory[*].[AvailabilityZone, SpotPrice]" --output text || true
        
        # Try to launch a test ARM64 instance directly
        echo "Trying to launch a test ARM64 instance directly..."
        INSTANCE_ID=$(AWS_PROFILE=${var.aws_profile} aws ec2 run-instances --image-id ami-0eb11ab33f229b26c --count 1 --instance-type t4g.small --region ${var.region} --query "Instances[0].InstanceId" --output text || echo "Failed to launch instance")
        
        if [ "$INSTANCE_ID" != "Failed to launch instance" ]; then
          echo "Successfully launched ARM64 test instance: $INSTANCE_ID"
          echo "Terminating test instance..."
          AWS_PROFILE=${var.aws_profile} aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region ${var.region}
          echo "This suggests the issue is with Karpenter configuration, not with ARM64 instance availability."
        else
          echo "Failed to launch ARM64 test instance. This suggests there might be capacity issues or account limits preventing ARM64 instance provisioning."
        fi
      fi
      
      # Monitor the deployment
      echo "Monitoring deployment..."
      kubectl get pods -l app=nginx -w &
      MONITOR_PID=$!
      sleep 30
      kill $MONITOR_PID || true
      
      # Check node distribution
      echo "Checking node distribution..."
      kubectl get nodes -L kubernetes.io/arch
      
      # Check pod distribution
      echo "Checking pod distribution..."
      kubectl get pods -l app=nginx -o wide
      
      # Verify proper distribution across architectures
      echo "Verifying pod distribution across architectures..."
      ARM64_PODS=$(kubectl get pods -l app=nginx -o wide | grep arm64 | wc -l)
      AMD64_PODS=$(kubectl get pods -l app=nginx -o wide | grep amd64 | wc -l)
      
      if [ $ARM64_PODS -eq 0 ]; then
        echo "Warning: No nginx pods scheduled on ARM64 nodes. Forcing redistribution..."
        # Delete some pods to force redistribution
        kubectl delete pods -l app=nginx --field-selector spec.nodeName=$(kubectl get nodes -l kubernetes.io/arch=amd64 -o name | head -1 | cut -d/ -f2) --limit=2
        
        # Wait for pods to be rescheduled
        echo "Waiting for pods to be rescheduled..."
        sleep 30
      fi
      
      # Check final distribution
      echo "Final node distribution:"
      kubectl get nodes -L kubernetes.io/arch
      echo "Final pod distribution:"
      kubectl get pods -l app=nginx -o wide
    EOT
  }
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
