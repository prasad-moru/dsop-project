# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name            = "${var.project}-${var.environment}"
  cluster_name    = "${local.name}-eks"
  node_group_name = "${local.name}-nodes"
  vpc_tags        = merge(var.additional_tags, { Name = "${local.name}-vpc" })
  eks_tags        = merge(var.additional_tags, { Name = "${local.name}-eks" })
  azs             = slice(data.aws_availability_zones.available.names, 0, var.availability_zones_count)
  microservices = [
    "ai-service",
    "makeline-service",
    "order-service",
    "product-service",
    "store-admin",
    "store-front",
    "store-virtual-customer",
    "store-virtual-worker"
  ]
}

# ---------------------------------------------------------------------------
# IAM Roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.eks_tags, { Name = "${local.cluster_name}-role" })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role" "node" {
  name = "${local.node_group_name}-role"

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

  tags = merge(local.eks_tags, { Name = "${local.node_group_name}-role" })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

resource "aws_iam_policy" "node_ecr_access" {
  name        = "${local.node_group_name}-ecr-access"
  description = "Enhanced ECR access for EKS nodes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.eks_tags
}

resource "aws_iam_role_policy_attachment" "node_ecr_access" {
  policy_arn = aws_iam_policy.node_ecr_access.arn
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_CloudWatchAgentServerPolicy" {
  count      = var.enable_cloudwatch_agent ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  name             = local.name
  cidr             = var.vpc_cidr
  azs              = local.azs
  subnet_cidr_bits = var.subnet_cidr_bits
  cluster_name     = local.cluster_name
  tags             = local.vpc_tags
}

# ---------------------------------------------------------------------------
# Node Security Group
# Created here (not in the node-group module) to break the circular
# dependency: EKS cluster SG <-> node SG
# ---------------------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${local.cluster_name}-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  tags = merge(
    local.eks_tags,
    {
      Name                                          = "${local.cluster_name}-node-sg"
      "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "nodes_internal" {
  description              = "Allow nodes to communicate with each other"
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.nodes.id
}

resource "aws_security_group_rule" "nodes_outbound" {
  security_group_id = aws_security_group.nodes.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound traffic"
}

# ---------------------------------------------------------------------------
# EKS Cluster
# ---------------------------------------------------------------------------

module "eks" {
  source = "../../modules/eks"

  depends_on = [
    module.vpc,
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_security_group.nodes
  ]

  cluster_name           = local.cluster_name
  cluster_version        = var.eks_version
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  public_subnet_ids      = module.vpc.public_subnet_ids
  cluster_role_arn       = aws_iam_role.cluster.arn
  node_security_group_id = aws_security_group.nodes.id
  enable_core_addons     = false
  tags                   = local.eks_tags
}

# OIDC Provider
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = module.eks.cluster_identity_oidc_issuer

  tags = merge(local.eks_tags, { Name = "${local.cluster_name}-eks-oidc" })
}

data "tls_certificate" "eks" {
  url        = module.eks.cluster_identity_oidc_issuer
  depends_on = [module.eks]
}

# Security group rules that need the cluster SG (created after EKS module)
resource "aws_security_group_rule" "cluster_to_nodes" {
  description              = "Allow cluster control plane to communicate with worker nodes"
  security_group_id        = module.eks.cluster_security_group_id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
  depends_on               = [module.eks]
}

resource "aws_security_group_rule" "nodes_cluster_inbound" {
  description              = "Allow worker nodes to receive communication from cluster control plane"
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = module.eks.cluster_security_group_id
  depends_on               = [module.eks]
}

# ---------------------------------------------------------------------------
# Node Group Module
# Security group is passed in from above - no circular dependency
# ---------------------------------------------------------------------------

module "node_group" {
  source = "../../modules/node-group"

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonSSMManagedInstanceCore,
    aws_security_group_rule.nodes_cluster_inbound
  ]

  cluster_name           = module.eks.cluster_name
  node_group_name        = local.node_group_name
  node_role_arn          = aws_iam_role.node.arn
  subnet_ids             = module.vpc.private_subnet_ids
  node_security_group_id = aws_security_group.nodes.id

  desired_size   = var.eks_node_desired_size
  min_size       = var.eks_node_min_size
  max_size       = var.eks_node_max_size
  disk_size      = var.eks_node_disk_size
  instance_types = var.eks_node_instance_types

  tags = local.eks_tags
}

# ---------------------------------------------------------------------------
# EBS CSI Driver
# ---------------------------------------------------------------------------

module "ebs_csi" {
  source = "../../modules/ebs-csi"

  depends_on = [module.eks, aws_iam_openid_connect_provider.eks, module.node_group]

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = aws_iam_openid_connect_provider.eks.url
}

# ---------------------------------------------------------------------------
# ALB Ingress Controller
# ---------------------------------------------------------------------------

module "alb_ingress" {
  source = "../../modules/alb-ingress"
  count  = var.enable_alb_ingress ? 1 : 0

  depends_on = [module.eks, aws_iam_openid_connect_provider.eks, module.node_group]

  cluster_name      = module.eks.cluster_name
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = aws_iam_openid_connect_provider.eks.url
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  name                    = "${local.name}-registry"
  image_tag_mutability    = "IMMUTABLE"
  scan_on_push            = true
  enable_lifecycle_policy = true
  image_count_to_keep     = 30
  node_role_arn           = aws_iam_role.node.arn

  tags = merge(
    local.eks_tags,
    {
      Environment = var.environment
      Name        = "${local.name}-ecr"
    }
  )

  depends_on = [aws_iam_role.node]
}
