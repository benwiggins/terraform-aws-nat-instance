
locals {
  instance_type_architectures    = { for f in var.instance_types : f => data.aws_ec2_instance_type.this[f].supported_architectures[0] }
  architectures                  = distinct([for k, v in local.instance_type_architectures : v])
  instance_type_launch_templates = { for f in var.instance_types : f => aws_launch_template.this[local.instance_type_architectures[f]].id }

  # Alpine's AMI names use "aarch64" rather than the "arm64" architecture value AWS uses elsewhere.
  architecture_alpine_names = {
    "x86_64" = "x86_64"
    "arm64"  = "aarch64"
  }
}

data "aws_ec2_instance_type" "this" {
  for_each      = toset(var.instance_types)
  instance_type = each.value
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# AMI of the latest Alpine Linux cloud-init image
# https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images
data "aws_ami" "this" {
  for_each = toset(local.architectures)

  most_recent = true
  owners      = ["538276064493"] # Alpine Linux

  filter {
    name   = "architecture"
    values = [each.value]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "name"
    values = ["alpine-3.*-${local.architecture_alpine_names[each.value]}-uefi-cloudinit-r*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "this" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
  description = "Security group for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_security_group_rule" "egress" {
  security_group_id = aws_security_group.this.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
}

resource "aws_security_group_rule" "ingress_any" {
  security_group_id = aws_security_group.this.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets_cidr_blocks
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
}

resource "aws_network_interface" "this" {
  security_groups   = [aws_security_group.this.id]
  subnet_id         = var.public_subnet
  source_dest_check = false
  description       = "ENI for NAT instance ${var.name}"
  tags              = local.common_tags
}

resource "aws_route" "this" {
  count                  = length(var.private_route_table_ids)
  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.this.id
}



resource "aws_launch_template" "this" {
  for_each = toset(local.architectures)

  name_prefix = "${var.name}-${each.value}-"
  image_id    = var.image_id != "" ? var.image_id : data.aws_ami.this[each.value].id
  key_name    = var.key_name

  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  user_data = base64encode(join("\n", [
    "#cloud-config",
    yamlencode({
      # https://cloudinit.readthedocs.io/en/latest/topics/modules.html
      write_files : concat([
        {
          path : "/opt/nat/runonce.sh",
          content : templatefile("${path.module}/runonce.sh", { eni_id = aws_network_interface.this.id }),
          permissions : "0755",
        },
        {
          path : "/opt/nat/snat.sh",
          content : file("${path.module}/snat.sh"),
          permissions : "0755",
        },
        {
          path : "/etc/init.d/snat",
          content : file("${path.module}/snat.initd"),
          permissions : "0755",
        },
      ], var.user_data_write_files),
      runcmd : concat([
        ["/opt/nat/runonce.sh"],
      ], var.user_data_runcmd),
    })
  ]))

  description = "Launch template for NAT instance ${var.name}"
  tags        = local.common_tags
}

resource "aws_autoscaling_group" "this" {
  name_prefix         = var.name
  desired_capacity    = var.enabled ? 1 : 0
  min_size            = var.enabled ? 1 : 0
  max_size            = 1
  vpc_zone_identifier = [var.public_subnet]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.use_spot_instance ? 0 : 1
      on_demand_percentage_above_base_capacity = var.use_spot_instance ? 0 : 100
    }
    launch_template {
      launch_template_specification {
        launch_template_id = local.instance_type_launch_templates[var.instance_types[0]]
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
          launch_template_specification {
            launch_template_id = local.instance_type_launch_templates[override.value]
            version            = "$Latest"
          }
        }
      }
    }
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = var.name
  role        = aws_iam_role.this.name

  tags = local.common_tags
}

resource "aws_iam_role" "this" {
  name_prefix = var.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = var.ssm_policy_arn
  role       = aws_iam_role.this.name
}

resource "aws_iam_role_policy" "eni" {
  role        = aws_iam_role.this.name
  name_prefix = var.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AttachOnlyNatEni"
        Effect = "Allow"
        Action = [
          "ec2:AttachNetworkInterface"
        ]
        Resource = [
          aws_network_interface.this.arn,
          "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        ]
      },
      {
        Sid    = "ModifyInstanceAttributes"
        Effect = "Allow"
        Action = [
          "ec2:ModifyInstanceAttribute"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"
      }
    ]
  })
}