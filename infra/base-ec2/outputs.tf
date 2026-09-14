# Outputs informativos para quien corre `tofu apply` a mano.
# El workflow de deploy NO depende de estos outputs: busca la instancia por
# tag Name=cat-webserver con AWS CLI, porque el state no persiste entre runs
# de GitHub Actions. Ver infra/README.md.

output "instance_id" {
  description = "ID de la instancia EC2 de la demo."
  value       = aws_instance.web.id
}

output "instance_public_ip" {
  description = "IP pública de la instancia (para abrir la app en el navegador)."
  value       = aws_instance.web.public_ip
}

output "ecr_repository_url" {
  description = "URL del repo ECR donde se publica la imagen de cat-app."
  value       = aws_ecr_repository.cat_app.repository_url
}
