# ---------------------------------------------------------------------------
# 1. Criação da Service Account Dedicada para a VM do Open WebUI
# ---------------------------------------------------------------------------
resource "google_service_account" "openwebui_vm_sa" {
  account_id   = "sa-gce-openwebui-develop"
  display_name = "Service Account para VM GCE do Open WebUI"
  project      = var.project_id
}

# ---------------------------------------------------------------------------
# 2. Atribuição de Permissão para leitura dos Segredos (GCP Secret Manager)
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret_iam_member" "sm_accessor" {
  secret_id = google_secret_manager_secret.db_connection_string.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openwebui_vm_sa.email}"
}

# ---------------------------------------------------------------------------
# 3. Atribuição de Permissão para Conexão via Cloud SQL Auth Proxy
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.openwebui_vm_sa.email}"
}

# ---------------------------------------------------------------------------
# 4. Atribuição de Permissões de SRE, Coleta de Métricas e Escrita de Logs
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.openwebui_vm_sa.email}"
}

resource "google_project_iam_member" "monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.openwebui_vm_sa.email}"
}
