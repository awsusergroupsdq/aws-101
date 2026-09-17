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

# --- EC2: solo instala Docker. El build/push/deploy de la imagen lo hacen los
#     null_resource de abajo, como parte de este mismo `tofu apply`. ---

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

# --- Build + push: corre DENTRO del apply, no en un workflow aparte.
#     Se dispara de nuevo (hash de docker/app) cada vez que cambia el código de la
#     app, así que "tofu apply" también sirve para redesplegar sin tocar la infra. ---

resource "null_resource" "build_and_push" {
  triggers = {
    app_sha1 = sha1(join("", [
      for f in fileset("${path.module}/../../docker/app", "**") :
      filesha1("${path.module}/../../docker/app/${f}")
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REPO="${aws_ecr_repository.cat_app.repository_url}"
      aws ecr get-login-password --region ${var.aws_region} \
        | docker login --username AWS --password-stdin "$${REPO%%/*}"
      docker build --platform linux/amd64 -t "$REPO:latest" "${path.module}/../../docker/app"
      docker push "$REPO:latest"
    EOT
  }
}

# --- Deploy: espera a que el agente de SSM esté online y corre el pull + run
#     remoto. Se re-dispara cada vez que hay una imagen nueva o una instancia nueva. ---

resource "null_resource" "deploy" {
  triggers = {
    image_id    = null_resource.build_and_push.id
    instance_id = aws_instance.web.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID="${aws_instance.web.id}"
      REPO="${aws_ecr_repository.cat_app.repository_url}"

      echo "Esperando a que el agente de SSM esté online en $INSTANCE_ID..."
      for i in $(seq 1 30); do
        PING=$(aws ssm describe-instance-information \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "")
        [ "$PING" = "Online" ] && break
        sleep 5
      done
      if [ "$PING" != "Online" ]; then
        echo "El agente de SSM nunca quedó online. Corré 'tofu apply' de nuevo en un rato."
        exit 1
      fi

      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "Deploy cat-app (tofu apply)" \
        --parameters commands="[
          \"cloud-init status --wait >/dev/null 2>&1 || true\",
          \"for i in \$(seq 1 24); do command -v docker >/dev/null 2>&1 && break; sleep 5; done\",
          \"aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin $${REPO%%/*}\",
          \"docker pull $REPO:latest\",
          \"docker stop cat-app || true\",
          \"docker rm cat-app || true\",
          \"docker run -d --name cat-app --restart unless-stopped -p 80:80 $REPO:latest\"
        ]" \
        --query 'Command.CommandId' --output text)

      aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" || true
      STATUS=$(aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text)
      echo "Deploy status: $STATUS"
      if [ "$STATUS" != "Success" ]; then
        aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --query 'StandardErrorContent' --output text
        exit 1
      fi
    EOT
  }

  depends_on = [null_resource.build_and_push]
}
