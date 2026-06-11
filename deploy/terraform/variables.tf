variable "project_id" {
  type        = string
  description = "ID do projeto do GCP para desenvolvimento e homologação de IA do ONR"
  default     = "projeto-ai-ml-develop"
}

variable "region" {
  type        = string
  description = "Região do GCP"
  default     = "southamerica-east1" # São Paulo
}

variable "zone" {
  type        = string
  description = "Zona específica do Compute Engine"
  default     = "southamerica-east1-a"
}

variable "vpc_name" {
  type        = string
  description = "Nome da VPC compartilhada que hospeda as subredes do ecossistema"
  default     = "vpc-shared-produtos"
}
