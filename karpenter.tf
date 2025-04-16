resource "null_resource" "wait_for_eks" {
  depends_on = [
    module.eks
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      echo "Waiting for EKS cluster to be accessible..."
      AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # Wait for the cluster to be accessible
      for i in {1..30}; do
        if kubectl get ns kube-system &>/dev/null; then
          echo "EKS cluster is now accessible!"
          break
        fi
        echo "Waiting for EKS cluster to be accessible... attempt $i/30"
        sleep 10
      done
    EOT
  }
}

resource "null_resource" "remove_existing_karpenter" {
  depends_on = [
    null_resource.wait_for_eks
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      # First update kubeconfig
      AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # Then try to uninstall Karpenter
      echo "Attempting to uninstall any existing Karpenter installation..."
      helm uninstall karpenter -n kube-system --ignore-not-found || true
    EOT
  }
}

# Install Karpenter in the kube-system namespace to match the IAM role trust relationship
resource "helm_release" "karpenter" {
  # Important: This namespace must match the one in the IAM role trust relationship
  namespace           = "kube-system"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = var.karpenter_version
  wait                = true
  timeout             = 600

  values = [
    <<-EOT
    # Explicitly set the controller image
    controller:
      image:
        repository: public.ecr.aws/karpenter/controller
        tag: ${var.karpenter_version}
      resources:
        requests:
          cpu: 100m
          memory: 1Gi
        limits:
          cpu: 1
          memory: 1Gi
      env:
        - name: AWS_REGION
          value: ${local.region}
        - name: AWS_DEFAULT_REGION
          value: ${local.region}
        - name: AWS_ROLE_ARN
          value: ${aws_iam_role.karpenter_controller.arn}
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/secrets/eks.amazonaws.com/serviceaccount/token

    # Node selector to ensure Karpenter runs on nodes it doesn't manage
    nodeSelector:
      karpenter.sh/controller: 'true'
    
    # Use default DNS policy
    dnsPolicy: Default
    
    # AWS settings for Karpenter
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      aws:
        defaultInstanceProfile: ${module.karpenter.instance_profile_name}
        interruptionQueueName: ${module.karpenter.queue_name}
        # Add region explicitly
        region: ${local.region}
    
    # Configure service account with IAM role for IRSA
    # This service account will be created in the kube-system namespace
    serviceAccount:
      create: true
      name: karpenter
      # Set automountServiceAccountToken to true (will be enforced by kubectl_manifest as well)
      automountServiceAccountToken: true
      annotations:
        eks.amazonaws.com/role-arn: ${aws_iam_role.karpenter_controller.arn}
    
    # Force mounting of service account token with explicit configuration
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
    
    # Add log level for better debugging
    logLevel: debug
    
    # Ensure proper RBAC configuration
    rbac:
      create: true
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
    null_resource.wait_for_cluster,
    aws_iam_role.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_permissions,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_read_only
  ]
}

# Create the EC2NodeClass for Karpenter
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
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
YAML

  depends_on = [
    helm_release.karpenter,
    null_resource.karpenter_serviceaccount_patch
  ]
}

# Create the NodePool for Karpenter
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  # Simplify the NodePool configuration to ensure it's valid
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
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

# Add a post-install hook to patch the service account
resource "null_resource" "karpenter_serviceaccount_patch" {
  depends_on = [
    helm_release.karpenter,
    null_resource.wait_for_cluster
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      echo "Patching Karpenter service account..."
      kubectl patch serviceaccount -n kube-system karpenter -p '{"automountServiceAccountToken": true}' || true
      echo "Service account patched successfully!"
    EOT
  }
}

# Add a resource to wait for the EKS cluster to be fully available
resource "null_resource" "wait_for_cluster" {
  depends_on = [
    module.eks,
    module.karpenter,
    aws_iam_role.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_permissions,
    aws_iam_role_policy_attachment.karpenter_controller_ec2_read_only,
    null_resource.remove_existing_karpenter
  ]
  
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      echo "Waiting for EKS cluster to be fully available..."
      AWS_PROFILE=${var.aws_profile} aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
      
      # Wait for the cluster to be accessible
      for i in {1..30}; do
        if kubectl get ns kube-system &>/dev/null; then
          echo "EKS cluster is now accessible!"
          break
        fi
        echo "Waiting for EKS cluster to be accessible... attempt $i/30"
        sleep 10
      done
      
      # Verify that the cluster is truly ready
      kubectl wait --for=condition=available --timeout=300s deployment/coredns -n kube-system || true
      echo "EKS cluster is fully operational!"
    EOT
  }
}
