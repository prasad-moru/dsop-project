# EKS Node Group Module
# Security group is created externally and passed in to avoid circular dependency
# with the EKS cluster security group

# Launch template for node group
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.node_group_name}-"
  description = "Launch template for EKS node group"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.disk_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name = "${var.node_group_name}-node"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      {
        Name = "${var.node_group_name}-volume"
      }
    )
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.node_group_name}-launch-template"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# EKS Node Group
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  ami_type       = var.ami_type
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  tags = merge(
    var.tags,
    {
      Name = var.node_group_name
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}
