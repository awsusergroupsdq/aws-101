variable "aws_region" {
  description = "Región de AWS donde se provisiona todo."
  type        = string
  default     = "us-east-1"
}

variable "task_cpu" {
  description = "CPU units de la Fargate task (256 = 0.25 vCPU)."
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Memoria en MiB de la Fargate task."
  type        = string
  default     = "512"
}
