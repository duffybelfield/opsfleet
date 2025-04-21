# IAM Policy for Karpenter Controller
resource "aws_iam_policy" "karpenter_controller" {
  name        = "KarpenterControllerPolicy-${local.name}"
  description = "IAM policy for Karpenter Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeImages",
          "ec2:DescribeVpcs",
          "eks:DescribeCluster",
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowPassingInstanceRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid       = "AllowScopedSSMActions"
        Effect    = "Allow"
        Action    = "ssm:GetParameter"
        Resource  = "arn:aws:ssm:*:*:parameter/aws/service/eks/optimized-ami/*"
      },
      {
        Sid       = "AllowPricing"
        Effect    = "Allow"
        Action    = "pricing:GetProducts"
        Resource  = "*"
      },
      {
        Sid    = "AllowInterruptionHandling"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "events:CreateEventBus",
          "events:PutRule",
          "events:PutTargets"
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowSQSTagging"
        Effect    = "Allow"
        Action    = "sqs:TagQueue"
        Resource  = "*"
      },
      {
        Sid    = "AllowECRTagging"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

# IAM Role for Karpenter Node
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${local.name}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

# Attach the AmazonEKSWorkerNodePolicy to the Karpenter Node role
resource "aws_iam_role_policy_attachment" "karpenter_node_eks_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# Attach the AmazonEKS_CNI_Policy to the Karpenter Node role
resource "aws_iam_role_policy_attachment" "karpenter_node_eks_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Attach the AmazonEC2ContainerRegistryReadOnly to the Karpenter Node role
resource "aws_iam_role_policy_attachment" "karpenter_node_ecr_readonly" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create the instance profile for Karpenter nodes
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${local.name}"
  role = aws_iam_role.karpenter_node.name
}

# SQS Queue for Karpenter Interruption Handling
resource "aws_sqs_queue" "karpenter_interruption_queue" {
  name                      = local.name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}

# EventBridge Rule for EC2 Spot Interruption Warnings
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name}-spot-interruption"
  description = "Capture EC2 Spot Instance Interruption Warnings"

  event_pattern = jsonencode({
    "source" : ["aws.ec2"],
    "detail-type" : ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.tags
}

# EventBridge Target for Spot Interruption Warnings
resource "aws_cloudwatch_event_target" "spot_interruption_target" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption_queue.arn
}

# SQS Queue Policy to allow EventBridge to send messages
resource "aws_sqs_queue_policy" "karpenter_interruption_queue_policy" {
  queue_url = aws_sqs_queue.karpenter_interruption_queue.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.spot_interruption.arn
          }
        }
      }
    ]
  })
}

# EventBridge Rule for EC2 Instance State-change Notifications
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${local.name}-instance-state-change"
  description = "Capture EC2 Instance State-change Notifications"

  event_pattern = jsonencode({
    "source" : ["aws.ec2"],
    "detail-type" : ["EC2 Instance State-change Notification"]
  })

  tags = local.tags
}

# EventBridge Target for Instance State-change Notifications
resource "aws_cloudwatch_event_target" "instance_state_change_target" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption_queue.arn
}

# EventBridge Rule for EC2 Instance Rebalance Recommendations
resource "aws_cloudwatch_event_rule" "instance_rebalance" {
  name        = "${local.name}-instance-rebalance"
  description = "Capture EC2 Instance Rebalance Recommendations"

  event_pattern = jsonencode({
    "source" : ["aws.ec2"],
    "detail-type" : ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.tags
}

# EventBridge Target for Instance Rebalance Recommendations
resource "aws_cloudwatch_event_target" "instance_rebalance_target" {
  rule      = aws_cloudwatch_event_rule.instance_rebalance.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption_queue.arn
}

# EventBridge Rule for Scheduled Change Events
resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${local.name}-scheduled-change"
  description = "Capture EC2 Scheduled Change Events"

  event_pattern = jsonencode({
    "source" : ["aws.health"],
    "detail-type" : ["AWS Health Event"],
    "detail" : {
      "service" : ["EC2"],
      "eventTypeCategory" : ["scheduledChange"]
    }
  })

  tags = local.tags
}

# EventBridge Target for Scheduled Change Events
resource "aws_cloudwatch_event_target" "scheduled_change_target" {
  rule      = aws_cloudwatch_event_rule.scheduled_change.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption_queue.arn
}

# Output the Karpenter controller policy ARN
output "karpenter_controller_policy_arn" {
  description = "ARN of the Karpenter Controller IAM policy"
  value       = aws_iam_policy.karpenter_controller.arn
}

# Output the Karpenter node instance profile name
output "karpenter_node_instance_profile_name" {
  description = "Name of the Karpenter Node instance profile"
  value       = aws_iam_instance_profile.karpenter_node.name
}

# Output the SQS queue URL
output "karpenter_interruption_queue_url" {
  description = "URL of the Karpenter interruption queue"
  value       = aws_sqs_queue.karpenter_interruption_queue.url
}