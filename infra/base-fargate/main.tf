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

# --- Task definition: en el primer apply el repo de ECR está vacío, así que las tasks
#     van a fallar el pull hasta que 02-deploy-app publique una imagen. Es esperado. ---

resource "aws_ecs_task_definition" "cat_app" {
  family                   = local.family_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution_role.arn

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
  name            = local.service_name
  cluster         = aws_ecs_cluster.cat_cluster.id
  task_definition = aws_ecs_task_definition.cat_app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }
}
