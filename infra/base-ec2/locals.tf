# Nombres hardcodeados a propósito (no vía output de tofu): el workflow de
# deploy los busca por tag/nombre con AWS CLI. Ver infra/README.md.
locals {
  ecr_repo_name = "cat-app"
  instance_name = "cat-webserver"
}
