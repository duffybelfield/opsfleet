# Karpenter Configuration Fixes

This document outlines the issues identified and fixes applied to properly manage Karpenter with Terraform and Helm.

## Issues Identified

1. **Missing EC2 Permissions**
   - Karpenter pods were failing with error: `operation error EC2: DescribeInstanceTypes`
   - The controller IAM role lacked necessary EC2 read permissions

2. **IAM Role Trust Relationship Namespace Mismatch**
   - The trust relationship was configured for `system:serviceaccount:karpenter:karpenter`
   - But Karpenter was deployed in the `kube-system` namespace
   - This caused the error: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

3. **Service Account Token Mounting**
   - The Helm chart was setting `automountServiceAccountToken: false`
   - This prevented the pod from accessing the token needed for IRSA

4. **Helm Chart Settings Structure**
   - The settings structure in the Helm values needed to match Karpenter 1.3.3 requirements
   - `clusterName` and `clusterEndpoint` needed to be at the top level of settings

## Fixes Applied

### 1. Added EC2 Read-Only Access

Added the AmazonEC2ReadOnlyAccess policy to the Karpenter controller role:

```hcl
resource "aws_iam_role_policy_attachment" "karpenter_ec2_read_only" {
  role       = "KarpenterController-20250415134905780600000001"
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
  
  depends_on = [
    module.karpenter
  ]
}
```

### 2. Fixed IAM Role Trust Relationship

Updated the trust policy to use the correct namespace:

```bash
aws iam update-assume-role-policy --role-name KarpenterController-20250415134905780600000001 --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::500931477396:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/C1BAD74F299E2A8C1279F17ED9282968"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-1.amazonaws.com/id/C1BAD74F299E2A8C1279F17ED9282968:sub": "system:serviceaccount:kube-system:karpenter",
          "oidc.eks.eu-west-1.amazonaws.com/id/C1BAD74F299E2A8C1279F17ED9282968:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}'
```

### 3. Patched Service Account (Required Workaround)

Applied a patch to enable token mounting:

```bash
kubectl patch serviceaccount -n kube-system karpenter -p '{"automountServiceAccountToken": true}'
```

This patch was necessary because even though we set `automountServiceAccountToken: true` in the Helm values, it wasn't being applied. The Karpenter Helm chart appears to override this setting.

### 4. Updated Helm Chart Values

Fixed the settings structure in karpenter.tf:

```hcl
settings:
  clusterName: ${module.eks.cluster_name}
  clusterEndpoint: ${module.eks.cluster_endpoint}
  aws:
    defaultInstanceProfile: ${module.karpenter.instance_profile_name}
    interruptionQueueName: ${module.karpenter.queue_name}
    region: ${local.region}
```

## Recommendations for Future Maintenance

1. **Add the patch to deployment scripts**:
   ```bash
   # After terraform apply, ensure service account token is mounted
   kubectl patch serviceaccount -n kube-system karpenter -p '{"automountServiceAccountToken": true}'
   ```

2. **Consider creating a custom post-install hook** in your Terraform configuration:
   ```hcl
   resource "null_resource" "karpenter_serviceaccount_patch" {
     depends_on = [helm_release.karpenter]
     
     provisioner "local-exec" {
       command = "kubectl patch serviceaccount -n kube-system karpenter -p '{\"automountServiceAccountToken\": true}'"
     }
   }
   ```

3. **Monitor for Helm chart updates** that might fix these issues in future versions

## Results

- Karpenter pods are now running successfully
- EC2NodeClass and NodePool resources are created and in Ready state
- The configuration properly integrates Terraform and Helm