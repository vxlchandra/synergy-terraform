# =============================================================================
# cloudsql.tf — Cloud SQL PostgreSQL Instance
# =============================================================================

# Random password for Cloud SQL user
resource "random_password" "db_password" {
  length  = 32
  special = true
}

# Store DB password in Secret Manager
resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.secrets["aeromon-db-password"].id
  secret_data = random_password.db_password.result
}

# Cloud SQL PostgreSQL Instance
# NOTE: imported from production. Config represents TARGET state (private IP).
# lifecycle ignore_changes prevents drift until VPC Direct migration is ready.
resource "google_sql_database_instance" "postgres" {
  name             = var.cloud_sql_instance_name
  database_version = var.cloud_sql_version
  region           = var.region

  lifecycle {
    ignore_changes = all
  }
  project          = var.project_id

  deletion_protection = true

  settings {
    tier              = var.cloud_sql_tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 50

    ip_configuration {
      # Private IP only — no public IP. Eliminates Google suspicious activity alerts.
      ipv4_enabled    = false
      private_network = google_compute_network.aeromontek_vpc.id
      require_ssl     = true
      ssl_mode        = "ENCRYPTED_ONLY"
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    database_flags {
      name  = "max_connections"
      value = "100"
    }

    database_flags {
      name  = "log_statement"
      value = "all"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
    }

    user_labels = {
      app       = "aeromontek"
      component = "database"
      tier      = "data"
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# Create database
resource "google_sql_database" "app_db" {
  name     = var.cloud_sql_database
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
}

# Create database user for application
# Password managed via gcloud/Secret Manager, not Terraform.
resource "google_sql_user" "app_user" {
  name     = var.cloud_sql_user
  instance = google_sql_database_instance.postgres.name
  password = random_password.db_password.result
  project  = var.project_id

  lifecycle {
    ignore_changes = [password]
  }
}

# Grant Secret Manager access to Spring Boot SA for DB password
resource "google_secret_manager_secret_iam_member" "classifier_db_password" {
  count     = var.enable_classifier ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets["aeromon-db-password"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.classifier[0].email}"
}
