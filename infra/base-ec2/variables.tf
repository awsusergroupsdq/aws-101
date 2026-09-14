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
