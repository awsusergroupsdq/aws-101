# --- Red: usamos la VPC y subnets default de la cuenta, sin crear red propia. ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# AMI de Amazon Linux 2023 más reciente, publicada por AWS vía SSM Parameter Store.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- ECR: repo compartido de nombre "cat-app" con el stack de Fargate (alternativo, no simultáneo). ---

resource "aws_ecr_repository" "cat_app" {
  name                 = local.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # permite borrar el repo aunque tenga imágenes (demo/workshop)

  image_scanning_configuration {
    scan_on_push = false
  }
}

# --- IAM: rol de instancia con permisos mínimos para SSM (deploy remoto) y pull de ECR. ---

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "cat-webserver-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "cat-webserver-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# --- Networking de la instancia: solo HTTP entrante. Sin SSH — el acceso es por SSM. ---

resource "aws_security_group" "web" {
  name        = "cat-webserver-sg"
  description = "Permite HTTP entrante para la demo de cat-app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cat-webserver-sg"
  }
}

# --- EC2: solo instala Docker. El pull + run de la imagen lo hace 02-deploy-app vía SSM,
#     porque en el primer apply el repo de ECR todavía está vacío. ---

resource "aws_instance" "web" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user
  EOF

  tags = {
    Name = local.instance_name
  }
}
