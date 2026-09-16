variable "aws_region" {
  description = "Región de AWS donde se provisiona todo."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para el servidor de la demo."
  type        = string
  default     = "t3.micro"
}

variable "my_ip_cidr" {
  description = <<-EOT
    CIDR permitido para SSH (puerto 22), pensado para que el presentador
    pueda entrar directo a la instancia además de por SSM. Dejalo vacío
    ("") para que se detecte tu IP pública automáticamente en el apply
    (vía https://checkip.amazonaws.com), o pasá la tuya explícita, ej.
    "203.0.113.10/32".
  EOT
  type        = string
  default     = ""
}
