resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.3.3"
  wait                = true
  timeout             = 600

  values = [
    <<-EOT
    # Explicitly set the controller image for 1.3.3
    controller:
      image:
        repository: public.ecr.aws/karpenter/controller
        tag: 1.3.3
      resources:
        requests:
          cpu: 1
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
          value: ${module.karpenter.iam_role_arn}
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
    serviceAccount:
      create: true
      name: karpenter
      automountServiceAccountToken: true
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    
    # Force mounting of service account token
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
    module.karpenter
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
  role: ${module.karpenter.node_iam_role_name}
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
    helm_release.karpenter
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
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64", "arm64"]
        - key: "karpenter.k8s.aws/instance-category"
          operator: In
          values: ["c", "m", "r"]
        - key: "karpenter.k8s.aws/instance-cpu"
          operator: In
          values: ["4", "8", "16", "32"]
        - key: "karpenter.k8s.aws/instance-hypervisor"
          operator: In
          values: ["nitro"]
        - key: "karpenter.k8s.aws/instance-generation"
          operator: Gt
          values: ["2"]
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
