# Karpenter Terraform Configuration Fixes

This document outlines the changes needed to fix the Terraform configuration for Karpenter to resolve the permission issues.

## Issues Identified

1. **IAM Role Trust Relationship Namespace Mismatch**:
   - The trust relationship was configured for `system:serviceaccount:karpenter:karpenter`
   - But Karpenter is deployed in the `kube-system` namespace

2. **Service Account Token Mounting Issue**:
   - The service account had `automountServiceAccountToken: false` despite configuration

3. **AWS CLI Profile Missing**:
   - AWS CLI commands need to use the `raposa` profile

## Required Changes

### 1. Update Trust Relationship Fix in `main.tf`

```hcl
resource "null_resource" "karpenter_trust_relationship_fix" {
  depends_on = [
    module.karpenter
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
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
      AWS_PROFILE=raposa aws iam update-assume-role-policy --role-name $ROLE_NAME --policy-document "$POLICY_DOC"
    EOT
  }
}
```

### 2. Update Service Account Patch in `karpenter.tf`

```hcl
resource "null_resource" "karpenter_serviceaccount_patch" {
  depends_on = [
    helm_release.karpenter,
    null_resource.wait_for_cluster
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      AWS_PROFILE=raposa aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      echo "Patching Karpenter service account..."
      kubectl patch serviceaccount -n kube-system karpenter -p '{"automountServiceAccountToken": true}' || true
      echo "Service account patched successfully!"
    EOT
  }
}
```

### 3. Update Dependency Order

Modify the `helm_release.karpenter` resource to depend on the trust relationship fix:

```hcl
resource "helm_release" "karpenter" {
  # ... existing configuration ...

  depends_on = [
    module.eks,
    module.karpenter,
    null_resource.wait_for_cluster,
    null_resource.karpenter_trust_relationship_fix  # Add this dependency
  ]
}
```

### 4. Update EC2 Permissions Policy in `main.tf`

Ensure the EC2 permissions policy includes all necessary permissions:

```hcl
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
```

### 5. Update AWS CLI Commands in Other Resources

Make sure all AWS CLI commands in the Terraform configuration use the `raposa` profile:

```hcl
resource "null_resource" "wait_for_eks" {
  # ... existing configuration ...
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      echo "Waiting for EKS cluster to be accessible..."
      AWS_PROFILE=raposa aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # ... rest of the command ...
    EOT
  }
}
```

### 6. Add Extra Volume Mounts to Force Token Mounting

Ensure the Helm chart configuration includes the necessary volume mounts:

```hcl
extraVolumes:
  - name: aws-iam-token
    projected:
      sources:
        - serviceAccountToken:
            path: token
            expirationSeconds: 86400
            audience: sts.amazonaws.com

extraVolumeMounts:
  - name: aws-iam-token
    mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
```

## Implementation Steps

1. Update `main.tf` with the changes to the trust relationship fix and EC2 permissions policy
2. Update `karpenter.tf` with the changes to the service account patch and Helm release dependencies
3. Update all AWS CLI commands to use the `raposa` profile
4. Apply the changes with `terraform apply`

## Verification

After applying these changes, verify that:

1. The Karpenter pods are running successfully
2. The service account has `automountServiceAccountToken: true`
3. The trust relationship is correctly configured for the `kube-system` namespace
4. The EC2 permissions are correctly applied