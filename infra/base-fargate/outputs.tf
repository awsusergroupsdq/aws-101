# Outputs informativos para quien corre `tofu apply` a mano.
# El workflow de deploy NO depende de estos outputs: busca el cluster/servicio
# por nombre con AWS CLI, porque el state no persiste entre runs de GitHub
# Actions. Ver infra/README.md.

output "ecs_cluster_name" {
  description = "Nombre del cluster de ECS."
  value       = aws_ecs_cluster.cat_cluster.name
}

output "ecs_service_name" {
  description = "Nombre del servicio de ECS."
  value       = aws_ecs_service.cat_service.name
}

output "ecr_repository_url" {
  description = "URL del repo ECR donde se publica la imagen de cat-app."
  value       = aws_ecr_repository.cat_app.repository_url
}
