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

  # Remote state in GCS — uncomment after running backend-bootstrap/
  # then: terraform init -migrate-state
  backend "gcs" {
    bucket = "zsds-terraform-state"
    prefix = "terraform/state/zsynergy"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Needed to resolve project number for the Pub/Sub service agent SA.
data "google_project" "project" {
  project_id = var.project_id
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

# Classifier needs read (PDFs) + create/overwrite (ChromaDB snapshot).
# objectViewer = get + list. objectCreator = create (overwrite is implicit).
# No delete permission — prevents accidental or malicious data loss.
resource "google_project_iam_member" "classifier_storage_viewer" {
  count   = var.enable_classifier ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.classifier[0].email}"
}

resource "google_project_iam_member" "classifier_storage_creator" {
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

  # Managed by deploy_gcp.sh, not Terraform. Ignore all drift.
  lifecycle {
    ignore_changes = all
  }

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
      # Centralized CORS — same origins as Classifier (from var.cors_allowed_origins)
      env {
        name  = "APP_CORS_ALLOWED_ORIGINS"
        value = var.cors_allowed_origins
      }

      env {
        name  = "CLOUD_SQL_INSTANCE"
        value = "${var.project_id}:${var.region}:${var.cloud_sql_instance_name}"
      }

      env {
        name = "DB_HOST"
        # Private IP via VPC Direct — no Cloud SQL Proxy sidecar needed
        value = google_sql_database_instance.postgres.private_ip_address
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

    # VPC Direct — routes DB traffic through private network.
    # Requires: Cloud SQL private IP on aeromontek-vpc (defined in cloudsql.tf).
    # NOTE: Do NOT apply this until `terraform apply` creates the private IP.
    # After apply: Cloud Run → VPC → Cloud SQL private IP (no public exposure).
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

  # Ingress: all traffic. Firebase App Hosting does NOT route as "internal"
  # to Cloud Run — it's a separate Google service that sends external HTTPS.
  # Network-layer lockdown requires Global External ALB + Cloud Armor.
  # App-layer security: Spring Boot FirebaseAuthFilter validates JWT on every request.
  # All endpoints require a valid Firebase ID token except /actuator/health/*.
  ingress = "INGRESS_TRAFFIC_ALL"

  launch_stage = "GA"
}

# Classifier API
resource "google_cloud_run_v2_service" "classifier" {
  count    = var.enable_classifier ? 1 : 0
  name     = var.classifier_service_name
  location = var.region
  project  = var.project_id

  # Managed by deploy_gcp.sh, not Terraform. Ignore all drift.
  lifecycle {
    ignore_changes = all
  }

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
        value = var.classifier_max_workers
      }
      env {
        name  = "MAX_EXTRACTION_WORKERS"
        value = var.classifier_extraction_workers
      }
      env {
        name  = "MAX_CLASSIFICATION_WORKERS"
        value = var.classifier_classification_workers
      }
      # ANONYMIZED_TELEMETRY is the correct ChromaDB >=0.4 env var.
      # The old CHROMADB_TELEMETRY=FALSE had no effect.
      env {
        name  = "ANONYMIZED_TELEMETRY"
        value = "False"
      }
      # GCS bucket for ChromaDB snapshot persistence.
      # Prevents re-embedding the IATA spec on every cold start.
      env {
        name  = "CHROMA_SNAPSHOT_BUCKET"
        value = var.classifier_chroma_snapshot_bucket
      }
      env {
        name  = "FLOW_CONTROL_MAX_MESSAGES"
        value = var.classifier_flow_control_max_messages
      }
      env {
        name  = "AUTO_CREATE_PUBSUB_RESOURCES"
        value = "false"
      }
      # Centralized CORS — same origins as Spring Boot API
      env {
        name  = "CORS_ORIGINS"
        value = var.cors_allowed_origins
      }
      # Service account used in the Pub/Sub push subscription OIDC token.
      # Matches the SA email passed to google_pubsub_subscription.classifier_request_sub.
      env {
        name  = "PUSH_SA_EMAIL"
        value = google_service_account.classifier[0].email
      }
      # Push endpoint URL for this service — set after first deploy.
      # Used for reference; Terraform owns the subscription (AUTO_CREATE_PUBSUB_RESOURCES=false).
      env {
        name  = "PUSH_ENDPOINT_URL"
        value = var.classifier_push_endpoint_url
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

# App Hosting SA invokes Spring Boot API — Firebase App Hosting runs as
# this SA. It cannot issue OIDC identity tokens, so allUsers is also
# required on the API service (app-layer auth is the gate).
resource "google_cloud_run_v2_service_iam_member" "apphosting_invokes_springboot" {
  count    = var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.springboot[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:firebase-app-hosting-compute@${var.project_id}.iam.gserviceaccount.com"
}

# allUsers invokes Spring Boot API — required because App Hosting cannot
# issue OIDC tokens. Spring Boot FirebaseAuthFilter validates every request.
# Remove when Cloud Armor + Global LB is in place.
resource "google_cloud_run_v2_service_iam_member" "public_invokes_springboot" {
  count    = var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.springboot[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
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

# Pub/Sub push delivery: grant the classifier SA the right to invoke its own Cloud Run service.
# The push subscription OIDC token uses this SA, so Cloud Run must accept it as an invoker.
resource "google_cloud_run_v2_service_iam_member" "pubsub_push_invokes_classifier" {
  count    = var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.classifier[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.classifier[0].email}"
}

# Allow the GCP Pub/Sub service agent to generate OIDC tokens for the classifier SA.
# Required for authenticated push subscription delivery.
resource "google_service_account_iam_member" "pubsub_agent_uses_classifier_sa" {
  count              = var.enable_classifier ? 1 : 0
  service_account_id = google_service_account.classifier[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
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

  # Push subscription (preferred for Cloud Run minScale=0 — Pub/Sub wakes the instance).
  # Set var.classifier_push_endpoint_url after first deploy to activate push mode.
  # When the variable is empty, a pull subscription is created (safe default for initial deploy).
  dynamic "push_config" {
    for_each = var.classifier_push_endpoint_url != "" ? [1] : []
    content {
      push_endpoint = var.classifier_push_endpoint_url
      oidc_token {
        service_account_email = google_service_account.classifier[0].email
        audience              = var.classifier_push_endpoint_url
      }
    }
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.topics["document-classification-request-dlq"].id
    max_delivery_attempts = 5
  }

  depends_on = [google_pubsub_topic.topics]
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

# =============================================================================
# Cloud Scheduler: Weekly aviation reference data refresh
# =============================================================================
# Triggers POST to /api/v1/admin/reference/refresh on the Spring Boot API.
# Cloud Scheduler authenticates via OIDC token from the Spring Boot SA,
# which has run.invoker on the API service. The admin endpoint validates
# the token via AdminDualAuthFilter (Google OIDC path).
#
# Schedule: Sunday 03:00 UTC (configurable via variable).
# Timeout: 600s (data download + bulk insert can take 2-5 min).

resource "google_cloud_scheduler_job" "reference_refresh" {
  count   = var.enable_springboot ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = "reference-data-weekly-refresh"

  description = "Weekly aviation reference data refresh (FAA + OpenSky + airports)"
  schedule    = var.reference_refresh_cron
  time_zone   = "UTC"

  retry_config {
    retry_count          = 2
    min_backoff_duration = "30s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.springboot[0].uri}/api/v1/admin/reference/refresh"

    oidc_token {
      service_account_email = google_service_account.springboot[0].email
      audience              = google_cloud_run_v2_service.springboot[0].uri
    }
  }

  depends_on = [google_cloud_run_v2_service.springboot]
}
