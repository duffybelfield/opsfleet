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
  default     = "startup-eks-cluster" # Will use the auto-generated name if not specified
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
