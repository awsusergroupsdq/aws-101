terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }

  # Sin backend remoto a propósito: el state es local/efímero.
  # Ver infra/README.md para el porqué y sus consecuencias.
}

provider "aws" {
  region = var.aws_region
}
