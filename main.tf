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
  # Extract the role name from the ARN using split and element functions
  role       = element(split("/", module.karpenter.iam_role_arn), 1)
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
  
  depends_on = [
    module.karpenter
  ]
}

# Attach the custom policy to the Karpenter role
resource "aws_iam_role_policy_attachment" "karpenter_ec2_permissions" {
  role       = element(split("/", module.karpenter.iam_role_arn), 1)
  policy_arn = aws_iam_policy.karpenter_ec2_permissions.arn
  
  depends_on = [
    module.karpenter
  ]
}

# Add resources to automatically apply Kubernetes manifests after cluster is ready
# Add a resource to fix the IAM role trust relationship
resource "null_resource" "karpenter_trust_relationship_fix" {
  depends_on = [
    module.karpenter
  ]
  
  provisioner "local-exec" {
    command = <<-EOT
      # Extract the role name from the ARN
      ROLE_NAME=$(echo ${module.karpenter.iam_role_arn} | cut -d'/' -f2)
      
      # Get the OIDC provider and format it correctly
      OIDC_PROVIDER="${module.eks.oidc_provider}"
      OIDC_PROVIDER_ARN="${module.eks.oidc_provider_arn}"
      
      # Create the policy document
      POLICY_DOC='{
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
              "Federated": "'$OIDC_PROVIDER_ARN'"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
              "StringEquals": {
                "'$OIDC_PROVIDER':sub": "system:serviceaccount:kube-system:karpenter",
                "'$OIDC_PROVIDER':aud": "sts.amazonaws.com"
              }
            }
          }
        ]
      }'
      
      # Update the trust relationship
      aws iam update-assume-role-policy --role-name $ROLE_NAME --policy-document "$POLICY_DOC"
    EOT
  }
}

resource "null_resource" "apply_kubernetes_manifests" {
  depends_on = [
    module.eks,
    module.karpenter,
    null_resource.wait_for_cluster,
    null_resource.karpenter_serviceaccount_patch,
    null_resource.karpenter_trust_relationship_fix,
    kubectl_manifest.karpenter_node_class,
    kubectl_manifest.karpenter_node_pool,
    aws_iam_role_policy_attachment.karpenter_ec2_read_only
  ]
  
  provisioner "local-exec" {
    command = <<-EOT
      # Configure kubectl
      aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # Wait for Karpenter to be ready
      echo "Waiting for Karpenter to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n kube-system || true
      
      # First apply the ConfigMap (required for nginx)
      echo "Applying ConfigMap..."
      kubectl apply -f nginx-config.yaml
      
      # Apply the ARM64 test pod to ensure ARM64 node provisioning
      echo "Applying ARM64 test pod to provision ARM64 node..."
      kubectl apply -f arm64-test-pod.yaml
      
      # Wait for ARM64 node to be provisioned
      echo "Waiting for ARM64 node to be provisioned..."
      for i in {1..10}; do
        if kubectl get nodes -l kubernetes.io/arch=arm64 | grep -q arm64; then
          echo "ARM64 node provisioned successfully!"
          break
        fi
        echo "Waiting for ARM64 node... attempt $i/10"
        sleep 30
      done
      
      # Wait for the ARM64 node to be ready
      echo "Waiting for ARM64 node to be ready..."
      kubectl wait --for=condition=ready --selector=kubernetes.io/arch=arm64 --timeout=300s node || true
      
      # Now apply the nginx deployment and service
      echo "Applying nginx deployment and service..."
      kubectl apply -f nginx-deployment.yaml
      kubectl apply -f nginx-service.yaml
      
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
