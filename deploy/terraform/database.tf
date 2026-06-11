# ---------------------------------------------------------------------------
# 1. Alocação de IP Privado para Conexão de Serviços (Private Service Access)
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "openwebui-db-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "projects/${var.project_id}/global/networks/${var.vpc_name}"
}

# ---------------------------------------------------------------------------
# 2. Conexão Privada de Serviços (VPC Peering com rede gerenciada do Google)
# ---------------------------------------------------------------------------
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = "projects/${var.project_id}/global/networks/${var.vpc_name}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# ---------------------------------------------------------------------------
# 3. Provisionamento da Instância Exclusiva Cloud SQL PostgreSQL
# ---------------------------------------------------------------------------
resource "google_sql_database_instance" "openwebui_postgresql" {
  name             = "openwebui-db"
  database_version = "POSTGRES_16" # Versão moderna e estável homologada pelo ONR
  region           = var.region
  depends_on       = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = "db-g1-small" # Tier com 1.7GB RAM dedicado (Ideal contra estouro físico de memória)
    availability_type = "ZONAL"       # Zonal para otimização financeira em ambiente develop (50% de economia)
    disk_size         = 20
    disk_type         = "PD_SSD"
    disk_autoresize   = true          # Expansão automática do disco do banco conforme uso

    ip_configuration {
      ipv4_enabled    = false # Desativa IP público (Acesso estritamente restrito à VPC privada)
      private_network = "projects/${var.project_id}/global/networks/${var.vpc_name}"
      require_ssl     = true  # Exige conexão criptografada SSL/TLS
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00" # Diário às 03:00 (UTC-3)
      point_in_time_recovery_enabled = true    # PITR ativo para restauração resiliente de dados
      transaction_log_retention_days = 7
    }

    # Ativação de Logs de Auditoria Corporativa no Cloud SQL
    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
  }
}

# Base de Dados Dedicada ao Open WebUI
resource "google_sql_database" "openwebui_db" {
  name     = "db_openwebui"
  instance = google_sql_database_instance.openwebui_postgresql.name
}

# Geração de Senha randômica forte para o Usuário do Banco
resource "random_password" "db_password" {
  length  = 24
  special = false
}

# Usuário de banco com privilégios restritos
resource "google_sql_user" "openwebui_user" {
  name     = "user_openwebui"
  instance = google_sql_database_instance.openwebui_postgresql.name
  password = random_password.db_password.result
}

# ---------------------------------------------------------------------------
# 4. Criação do Segredo Criptografado no GCP Secret Manager
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "db_connection_string" {
  secret_id = "openwebui-database-url"
  labels = {
    app = "openwebui"
    env = "develop"
  }
  replication {
    auto {}
  }
}

# Escrita da connection string encriptada
resource "google_secret_manager_secret_version" "db_connection_string_val" {
  secret      = google_secret_manager_secret.db_connection_string.id
  secret_data = "postgresql://user_openwebui:${random_password.db_password.result}@${google_sql_database_instance.openwebui_postgresql.private_ip_address}:5432/db_openwebui?sslmode=require"
}
