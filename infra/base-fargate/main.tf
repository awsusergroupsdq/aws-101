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

# --- ECR: repo compartido de nombre "cat-app" con el stack de EC2 (alternativo, no simultáneo). ---

resource "aws_ecr_repository" "cat_app" {
  name                 = local.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # permite borrar el repo aunque tenga imágenes (demo/workshop)

  image_scanning_configuration {
    scan_on_push = false
  }
}

# --- Cluster de ECS (sin capacity provider EC2: todo corre en Fargate). ---

resource "aws_ecs_cluster" "cat_cluster" {
  name = local.cluster_name
}

# --- Logs de los containers. ---

resource "aws_cloudwatch_log_group" "cat_app" {
  name              = local.log_group
  retention_in_days = 1 # workshop: no necesitamos retención larga
}

# --- IAM: rol de ejecución que usa el agente de ECS para arrancar la task (pull de ECR + logs). ---

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution_role" {
  name               = "cat-app-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_role_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- IAM: task role para ECS Exec — shell interactivo dentro del container, vía SSM.
#     Fargate no tiene un host al que hacerle SSH; esto es el equivalente sin abrir
#     ningún puerto (a diferencia del SSH que sí se agrega en base-ec2). ---

resource "aws_iam_role" "task_role" {
  name               = "cat-app-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_role_exec" {
  name   = "ecs-exec"
  role   = aws_iam_role.task_role.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

# --- Networking del servicio: solo HTTP entrante. Sin ALB (no hace falta para la demo). ---

resource "aws_security_group" "service" {
  name        = "cat-service-sg"
  description = "Permite HTTP entrante para la demo de cat-app en Fargate"
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
    Name = "cat-service-sg"
  }
}

# --- Task definition: apunta a cat-app:latest. Al crear el servicio (más abajo) la
#     primera task intenta arrancar antes de que exista la imagen (el ECR recién se
#     llena en null_resource.build_and_push, después) — esa primera task falla el
#     pull, y el null_resource.deploy la reemplaza con un force-new-deployment una
#     vez que la imagen ya está publicada. Es esperado, y pasa dentro del mismo apply. ---

resource "aws_ecs_task_definition" "cat_app" {
  family                   = local.family_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${aws_ecr_repository.cat_app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cat_app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cat-app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "cat_service" {
  name                   = local.service_name
  cluster                = aws_ecs_cluster.cat_cluster.id
  task_definition        = aws_ecs_task_definition.cat_app.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true # habilita `aws ecs execute-command` (shell vía SSM, sin puertos)

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
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

# --- Deploy: fuerza un nuevo deployment del servicio y espera a que estabilice.
#     Se re-dispara cada vez que hay una imagen nueva. ---

resource "null_resource" "deploy" {
  triggers = {
    image_id = null_resource.build_and_push.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws ecs update-service \
        --cluster ${aws_ecs_cluster.cat_cluster.name} \
        --service ${aws_ecs_service.cat_service.name} \
        --force-new-deployment \
        --region ${var.aws_region} >/dev/null
      aws ecs wait services-stable \
        --cluster ${aws_ecs_cluster.cat_cluster.name} \
        --services ${aws_ecs_service.cat_service.name} \
        --region ${var.aws_region}
      echo "Servicio estabilizado."
    EOT
  }

  depends_on = [null_resource.build_and_push, aws_ecs_service.cat_service]
}

# --- IP pública de la task, resuelta DESPUÉS del deploy (depends_on obliga a
#     OpenTofu a leer esto recién en el apply, no en el plan) — así sale como
#     output normal, sin tener que correr ningún comando aparte. Sin ALB, esta
#     IP cambia cada vez que la task se recrea (redeploy, o si ECS la reinicia
#     sola); volvé a correr `tofu apply` o `tofu apply -replace` de este data
#     source para refrescarla si hace falta. ---

data "external" "task_ip" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    TASK_ARN=$(aws ecs list-tasks \
      --cluster ${aws_ecs_cluster.cat_cluster.name} \
      --service-name ${aws_ecs_service.cat_service.name} \
      --region ${var.aws_region} --query 'taskArns[0]' --output text)
    ENI_ID=$(aws ecs describe-tasks \
      --cluster ${aws_ecs_cluster.cat_cluster.name} --tasks "$TASK_ARN" \
      --region ${var.aws_region} \
      --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
    IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
      --region ${var.aws_region} \
      --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    printf '{"ip":"%s"}' "$IP"
  EOT
  ]

  depends_on = [null_resource.deploy]
}
