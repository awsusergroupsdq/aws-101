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

output "app_url" {
  description = "Abrí esto en el navegador una vez que 02-deploy-app haya corrido."
  value       = "http://${aws_instance.web.public_ip}"
}

# --- SSH: para debug directo del presentador, además de SSM. ---

output "my_ip_cidr" {
  description = "CIDR que quedó habilitado para SSH (tu IP detectada automáticamente, o la que pasaste en var.my_ip_cidr)."
  value       = local.my_ip_cidr
}

output "ssh_private_key_pem" {
  description = "Private key SSH (formato OpenSSH). Sensitive: no se imprime sola, pedila con 'tofu output -raw'."
  value       = tls_private_key.ssh.private_key_openssh
  sensitive   = true
}

output "ssh_command" {
  description = "Copiá y pegá: guarda la private key en un archivo y te conecta por SSH."
  value       = "tofu output -raw ssh_private_key_pem > cat-webserver.pem && chmod 400 cat-webserver.pem && ssh -i cat-webserver.pem ec2-user@${aws_instance.web.public_ip}"
}
