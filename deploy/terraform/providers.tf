terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.10.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.0"
    }
  }
  backend "gcs" {
    bucket = "onr-terraform-state-develop"
    prefix = "ia/openwebui"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
