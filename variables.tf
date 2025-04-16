variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS profile to use for authentication"
  type        = string
  default     = "raposa"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = null # Will use the auto-generated name if not specified
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "List of instance types for the EKS managed node group"
  type        = list(string)
  default     = ["m5.large"]
}

variable "node_group_min_size" {
  description = "Minimum size of the EKS managed node group"
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum size of the EKS managed node group"
  type        = number
  default     = 3
}

variable "node_group_desired_size" {
  description = "Desired size of the EKS managed node group"
  type        = number
  default     = 2
}

variable "karpenter_version" {
  description = "Version of Karpenter to install"
  type        = string
  default     = "1.3.3"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "k8s_manifest_files" {
  description = "List of Kubernetes manifest files to apply"
  type        = list(string)
  default     = ["nginx-config.yaml", "arm64-test-pod.yaml", "nginx-deployment.yaml", "nginx-service.yaml"]
}

variable "karpenter_instance_categories" {
  description = "List of EC2 instance categories for Karpenter to use"
  type        = list(string)
  default     = ["c", "m", "r", "t"]
}

variable "karpenter_instance_cpu" {
  description = "List of EC2 instance CPU values for Karpenter to use"
  type        = list(string)
  default     = ["2", "4", "8", "16", "32"]
}

variable "karpenter_cpu_limit" {
  description = "CPU limit for Karpenter NodePool"
  type        = number
  default     = 1000
}

variable "karpenter_arm64_families" {
  description = "List of ARM64 instance families for Karpenter to use"
  type        = list(string)
  default     = ["a1", "c6g", "c7g", "m6g", "m7g", "r6g", "r7g", "t4g"]
}