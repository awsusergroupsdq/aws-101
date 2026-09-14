# Nombres hardcodeados a propósito (no vía output de tofu): el workflow de
# deploy los busca por nombre con AWS CLI. Ver infra/README.md.
locals {
  ecr_repo_name  = "cat-app"
  cluster_name   = "cat-cluster"
  service_name   = "cat-service"
  family_name    = "cat-app"
  container_name = "cat-app"
  log_group      = "/ecs/cat-app"
}
