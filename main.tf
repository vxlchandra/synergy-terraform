# =============================================================================
# main.tf — ZSynergy / AeroMontek Terraform Configuration
# =============================================================================
# Provisions all GCP resources for the ZSynergy platform:
#   - Artifact Registry
#   - Service Accounts + IAM
#   - Cloud Run services (Spring Boot, Classifier)
#   - Pub/Sub topics + subscriptions
#   - EventArc triggers
#   - Secret Manager secrets
#   - Cloud Build triggers
#
# Usage:
#   cd terraform
#   terraform init
#   terraform plan -var-file="vars/zsynergy.tfvars"
#   terraform apply -var-file="vars/zsynergy.tfvars"
#
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # backend "gcs" {
  #   # Use a GCS bucket for state storage
  #   # bucket = "zsds-terraform-state"
  #   # prefix = "terraform/state"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# Enable Required APIs
# =============================================================================
resource "google_project_service" "required_apis" {
  for_each = toset(var.enabled_apis)
  project  = var.project_id
  service  = each.value

  disable_on_destroy = false
}

# =============================================================================
# Artifact Registry
# =============================================================================
resource "google_artifact_registry_repository" "docker_repo" {
  count         = var.enable_artifact_registry ? 1 : 0
  location      = var.repo_location
  project       = var.project_id
  repository_id = var.repo_name
  description   = "ZSynergy Docker images"
  format        = "DOCKER"

  docker_config {
    immutable_tags = false
  }
}

# =============================================================================
# Service Accounts
# =============================================================================
resource "google_service_account" "frontend" {
  count        = var.enable_frontend ? 1 : 0
  account_id   = "${var.sa_prefix}-frontend"
  display_name = "ZSDS Frontend Service Account"
  project      = var.project_id
}

resource "google_service_account" "springboot" {
  count        = var.enable_springboot ? 1 : 0
  account_id   = "${var.sa_prefix}-springboot"
  display_name = "ZSDS Spring Boot API Service Account"
  project      = var.project_id
}

resource "google_service_account" "classifier" {
  count        = var.enable_classifier ? 1 : 0
  account_id   = "${var.sa_prefix}-classifier"
  display_name = "ZSDS Classifier API Service Account"
  project      = var.project_id
}

# =============================================================================
# IAM Roles — Service Accounts
# =============================================================================

# Spring Boot SA roles
resource "google_project_iam_member" "springboot_cloudsql" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_project_iam_member" "springboot_pubsub_pub" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_project_iam_member" "springboot_pubsub_sub" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_project_iam_member" "springboot_storage" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_project_iam_member" "springboot_firestore" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.springboot[0].email}"
}

# Classifier SA roles
resource "google_project_iam_member" "classifier_cloudsql" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_project_iam_member" "classifier_pubsub_pub" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_project_iam_member" "classifier_pubsub_sub" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

# NOTE: pubsub.editor and pubsub.viewer removed — covered by publisher + subscriber roles above

resource "google_project_iam_member" "classifier_storage" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_project_iam_member" "classifier_firestore" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_project_iam_member" "classifier_logging" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

# Frontend SA can invoke backend services
resource "google_project_iam_member" "frontend_run_invoker" {
  count   = var.enable_frontend ? 1 : 0
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.frontend[0].email}"
}

# =============================================================================
# Secret Manager Secrets
# =============================================================================
resource "google_secret_manager_secret" "secrets" {
  for_each  = toset(var.secret_names)
  project   = var.project_id
  secret_id = each.key

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

# Grant SA access to secrets
resource "google_secret_manager_secret_iam_member" "springboot_db_password" {
  count     = var.enable_springboot ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets["aeromon-db-password"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_secret_manager_secret_iam_member" "springboot_admin_sa" {
  count     = var.enable_springboot ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets["aeromon-firebase-admin-sa"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_secret_manager_secret_iam_member" "classifier_admin_sa" {
  count     = var.enable_classifier ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets["aeromon-firebase-admin-sa"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_secret_manager_secret_iam_member" "classifier_api_keys" {
  for_each  = var.enable_classifier ? toset(["aeromon-openai-api-key", "aeromon-gemini-api-key", "aeromon-hf-token"]) : toset([])
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.classifier[0].email}"
}

# =============================================================================
# Cloud Run Services
# =============================================================================

# Spring Boot API
resource "google_cloud_run_v2_service" "springboot" {
  count    = var.enable_springboot ? 1 : 0
  name     = var.springboot_service_name
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.springboot[0].email

    containers {
      image = var.springboot_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.springboot_cpu
          memory = "${var.springboot_memory}Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "FIREBASE_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "SPRING_PROFILES_ACTIVE"
        value = "cloudrun"
      }
      env {
        name  = "SERVER_PORT"
        value = "8080"
      }

      env {
        name  = "CLOUD_SQL_INSTANCE"
        value = "${var.project_id}:${var.region}:${var.cloud_sql_instance_name}"
      }

      env {
        name  = "DB_HOST"
        value = "/cloudsql/${var.project_id}:${var.region}:${var.cloud_sql_instance_name}"
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-db-password"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "FIREBASE_ADMIN_SA_PATH"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-firebase-admin-sa"].secret_id
            version = "latest"
          }
        }
      }
    }

    scaling {
      min_instance_count = var.springboot_min_instances
      max_instance_count = var.springboot_max_instances
    }

    max_instance_request_concurrency = var.springboot_concurrency

    timeout = "300s"

    vpc_access {
      network_interfaces {
        network    = google_compute_network.aeromontek_vpc.name
        subnetwork = google_compute_subnetwork.springboot_subnet.name
      }
      egress = "ALL_TRAFFIC"
    }

    labels = {
      app       = "aeromontek"
      component = "api"
      tier      = "backend"
    }
  }

  # Public ingress (authenticated via Firebase JWT at app level)
  ingress = "INGRESS_TRAFFIC_ALL"

  launch_stage = "GA"
}

# Classifier API
resource "google_cloud_run_v2_service" "classifier" {
  count    = var.enable_classifier ? 1 : 0
  name     = var.classifier_service_name
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.classifier[0].email

    containers {
      image = var.classifier_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.classifier_cpu
          memory = "${var.classifier_memory}Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "FIRESTORE_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "MAX_WORKERS"
        value = "5"
      }
      env {
        name  = "CHROMADB_TELEMETRY"
        value = "FALSE"
      }

      env {
        name = "OPENAI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-openai-api-key"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "GEMINI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-gemini-api-key"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "HF_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-hf-token"].secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "FIREBASE_ADMIN_SA_PATH"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-firebase-admin-sa"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "CLOUD_SQL_CONNECTION_NAME"
        value = google_sql_database_instance.postgres.connection_name
      }

      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.postgres.private_ip_address
      }

      env {
        name  = "DB_NAME"
        value = var.cloud_sql_database
      }

      env {
        name  = "DB_USER"
        value = var.cloud_sql_user
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secrets["aeromon-db-password"].secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "SPRINGBOOT_API_URL"
        value = "https://${google_cloud_run_v2_service.springboot[0].uri}"
      }
    }

    scaling {
      min_instance_count = var.classifier_min_instances
      max_instance_count = var.classifier_max_instances
    }

    max_instance_request_concurrency = var.classifier_concurrency

    timeout = "600s"

    vpc_access {
      network_interfaces {
        network    = google_compute_network.aeromontek_vpc.name
        subnetwork = google_compute_subnetwork.classifier_subnet.name
      }
      egress = "ALL_TRAFFIC"
    }

    labels = {
      app       = "aeromontek"
      component = "classifier"
      tier      = "backend"
    }
  }

  ingress      = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"
}

# =============================================================================
# Cloud Run IAM — Internal Invocation
# =============================================================================
resource "google_cloud_run_v2_service_iam_member" "frontend_invokes_springboot" {
  count    = var.enable_frontend && var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.springboot[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.frontend[0].email}"
}

resource "google_cloud_run_v2_service_iam_member" "springboot_invokes_classifier" {
  count    = var.enable_springboot && var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.classifier[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.springboot[0].email}"
}

resource "google_cloud_run_v2_service_iam_member" "frontend_invokes_classifier" {
  count    = var.enable_frontend && var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.classifier[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.frontend[0].email}"
}

# NEW: Classifier can invoke Spring Boot (bidirectional communication)
resource "google_cloud_run_v2_service_iam_member" "classifier_invokes_springboot" {
  count    = var.enable_springboot && var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.springboot[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.classifier[0].email}"
}

# =============================================================================
# Pub/Sub Topics
# =============================================================================
resource "google_pubsub_topic" "topics" {
  for_each = toset(var.pubsub_topics)
  project  = var.project_id
  name     = each.key

  message_retention_duration = var.pubsub_retention_duration
}

# Pub/Sub Subscriptions
resource "google_pubsub_subscription" "classifier_request_sub" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  name    = "document-classification-request-python-sub"
  topic   = google_pubsub_topic.topics["document-classification-request"].name

  ack_deadline_seconds       = 300
  message_retention_duration = "604800s" # 7 days
}

resource "google_pubsub_subscription" "result_springboot_sub" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  name    = "document-classification-result-springboot-sub"
  topic   = google_pubsub_topic.topics["document-classification-result"].name

  ack_deadline_seconds       = 300
  message_retention_duration = "604800s"
}

resource "google_pubsub_subscription" "progress_firebase_sub" {
  count   = var.enable_firebase_functions ? 1 : 0
  project = var.project_id
  name    = "document-classification-progress-firebase-sub"
  topic   = google_pubsub_topic.topics["document-classification-progress"].name

  ack_deadline_seconds       = 60
  message_retention_duration = "86400s" # 1 day
}

# =============================================================================
# EventArc Triggers
# =============================================================================
resource "google_eventarc_trigger" "storage_springboot" {
  count    = var.enable_eventarc && var.enable_springboot ? 1 : 0
  name     = "storage-finalize-springboot-trigger"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.topics["storage-finalize-events"].id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.springboot[0].name
      region  = var.region
      path    = "/api/storage/finalize"
    }
  }

  service_account = google_service_account.springboot[0].email
}

resource "google_eventarc_trigger" "storage_classifier" {
  count    = var.enable_eventarc && var.enable_classifier ? 1 : 0
  name     = "storage-finalize-classifier-trigger"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.topics["storage-finalize-events"].id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.classifier[0].name
      region  = var.region
      path    = "/storage/finalize"
    }
  }

  service_account = google_service_account.classifier[0].email
}

# =============================================================================
# Cloud Build Triggers (CI/CD)
# =============================================================================
resource "google_cloudbuild_trigger" "main_trigger" {
  count    = var.enable_cloudbuild_trigger ? 1 : 0
  project  = var.project_id
  name     = "zsds-main-trigger"
  location = var.region

  github {
    owner = var.github_owner
    name  = var.github_repo
    push {
      branch = var.github_branch
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _REPO_LOCATION = var.repo_location
    _REPO_NAME     = var.repo_name
    _REGION        = var.region
  }

  include_build_logs = "INCLUDE_BUILD_LOGS_WITH_STATUS"
}
