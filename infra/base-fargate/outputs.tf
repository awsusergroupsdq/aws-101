# Outputs para quien corre `tofu apply` — el build+push+deploy también vive
# en este mismo stack (null_resource al final de main.tf), pero el destroy
# (03-destroy.yml) sigue buscando los recursos por nombre con AWS CLI, no
# por estos outputs, porque el state no persiste entre runs de GitHub
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

output "app_url" {
  description = "Abrí esto en el navegador — la app ya está corriendo después del apply."
  value       = "http://${data.external.task_ip.result.ip}"
}

# Sin ALB, esta IP cambia si la task se recrea (redeploy, o si ECS la
# reinicia sola). Si sospechás que quedó vieja sin haber corrido un apply
# nuevo, este comando te la trae fresca sin tocar el resto del state.
output "find_ip_command" {
  description = "Para refrescar la IP a mano, sin re-aplicar. Normalmente no hace falta: usá app_url."
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
