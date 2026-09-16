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

# --- Mi IP pública, para restringir el SSH solo al presentador. ---
# Si var.my_ip_cidr viene vacío, se detecta automáticamente en cada apply.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = var.my_ip_cidr != "" ? var.my_ip_cidr : "${chomp(data.http.my_ip.response_body)}/32"
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

# --- Networking de la instancia: HTTP para todo el mundo, SSH solo para el presentador. ---
# El deploy en sí sigue siendo por SSM (no depende de esta regla de SSH).

resource "aws_security_group" "web" {
  name        = "cat-webserver-sg"
  description = "Permite HTTP entrante para la demo de cat-app, y SSH solo desde la IP del presentador"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH (solo la IP del presentador, ver var.my_ip_cidr)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
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

# --- Key pair para SSH: generado por tofu, la private key vive solo en el state local
#     (mismo trade-off de "todo efímero" que el resto del stack — nunca se commitea). ---

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "cat-webserver-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# --- EC2: solo instala Docker. El pull + run de la imagen lo hace 02-deploy-app vía SSM,
#     porque en el primer apply el repo de ECR todavía está vacío. ---

resource "aws_instance" "web" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = aws_key_pair.ssh.key_name

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
