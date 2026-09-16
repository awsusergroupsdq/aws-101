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

# --- La IP pública de la task no existe hasta que 02-deploy-app la despliegue,
#     así que no se puede dar como valor fijo — se da el comando para conseguirla. ---

output "find_ip_command" {
  description = "Corré esto después de 02-deploy-app para conseguir la IP pública de la app."
  value       = "aws ecs describe-tasks --cluster ${aws_ecs_cluster.cat_cluster.name} --tasks $(aws ecs list-tasks --cluster ${aws_ecs_cluster.cat_cluster.name} --service-name ${aws_ecs_service.cat_service.name} --query 'taskArns[0]' --output text) --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text"
}

# --- ECS Exec: shell interactivo dentro del container, vía SSM (sin abrir puertos).
#     Necesita el Session Manager plugin de AWS CLI instalado en tu máquina. ---

output "list_tasks_command" {
  description = "Lista las tasks corriendo — de ahí sacás el TASK_ID para exec_command_template."
  value       = "aws ecs list-tasks --cluster ${aws_ecs_cluster.cat_cluster.name} --service-name ${aws_ecs_service.cat_service.name}"
}

output "exec_command_template" {
  description = "Reemplazá <TASK_ID> por uno de list_tasks_command."
  value       = "aws ecs execute-command --cluster ${aws_ecs_cluster.cat_cluster.name} --task <TASK_ID> --container ${local.container_name} --interactive --command \"/bin/sh\""
}
