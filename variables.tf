# =============================================================================
# variables.tf — ZSynergy / AeroMontek Terraform Variables
# =============================================================================

# ─── Project ─────────────────────────────────────────────────────────────
variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "zsynergy"
}

variable "region" {
  description = "Default GCP region for Cloud Run, EventArc, etc."
  type        = string
  default     = "us-east4"
}

# ─── VPC & Networking ────────────────────────────────────────────────────────
variable "vpc_name" {
  description = "VPC network name"
  type        = string
  default     = "aeromontek-vpc"
}

variable "springboot_subnet_cidr" {
  description = "CIDR range for Spring Boot subnet"
  type        = string
  default     = "10.10.0.0/24"
}

variable "classifier_subnet_cidr" {
  description = "CIDR range for Classifier subnet"
  type        = string
  default     = "10.10.1.0/24"
}

variable "private_svc_subnet_cidr" {
  description = "CIDR range for private service connection (Cloud SQL)"
  type        = string
  default     = "10.10.2.0/24"
}

# ─── Cloud SQL ───────────────────────────────────────────────────────────────
variable "cloud_sql_instance_name" {
  description = "Existing Cloud SQL PostgreSQL instance name"
  type        = string
  default     = "zsynergy-pg"
}

variable "cloud_sql_database" {
  description = "Database name within the Cloud SQL instance"
  type        = string
  default     = "zsynergy"
}

variable "cloud_sql_user" {
  description = "Database user for Cloud SQL"
  type        = string
  default     = "appuser"
}

variable "cloud_sql_tier" {
  description = "Cloud SQL machine type (e.g., db-g1-small, db-custom-2-8192)"
  type        = string
  default     = "db-g1-small"
}

variable "cloud_sql_version" {
  description = "PostgreSQL version for Cloud SQL"
  type        = string
  default     = "POSTGRES_15"
}

# ─── Storage Buckets ─────────────────────────────────────────────────────────
variable "documents_bucket_name" {
  description = "GCS bucket name for documents"
  type        = string
  default     = "zsynergy-documents"
}

variable "uploads_bucket_name" {
  description = "GCS bucket name for uploads"
  type        = string
  default     = "zsynergy-uploads"
}

variable "repo_location" {
  description = "Artifact Registry repository location"
  type        = string
  default     = "us"
}

# ─── Repositories ────────────────────────────────────────────────────────
variable "repo_name" {
  description = "Artifact Registry Docker repository name"
  type        = string
  default     = "zsynergy"
}

# ─── Component Toggles ───────────────────────────────────────────────────
variable "enable_artifact_registry" {
  description = "Whether to create Artifact Registry repository"
  type        = bool
  default     = true
}

variable "enable_frontend" {
  description = "Deploy frontend service account and resources"
  type        = bool
  default     = true
}

variable "enable_springboot" {
  description = "Deploy Spring Boot Cloud Run service"
  type        = bool
  default     = true
}

variable "enable_classifier" {
  description = "Deploy Classifier Cloud Run service"
  type        = bool
  default     = true
}

variable "enable_firebase_functions" {
  description = "Create Pub/Sub subscriptions for Firebase Functions"
  type        = bool
  default     = true
}

variable "enable_eventarc" {
  description = "Create EventArc triggers for storage events"
  type        = bool
  default     = true
}

variable "enable_cloudbuild_trigger" {
  description = "Create Cloud Build CI/CD trigger"
  type        = bool
  default     = false
}

# ─── Service Accounts ────────────────────────────────────────────────────
variable "sa_prefix" {
  description = "Prefix for service account names"
  type        = string
  default     = "zsds-sa"
}

# ─── Container Images (set after Cloud Build) ────────────────────────────
variable "springboot_image" {
  description = "Docker image for Spring Boot API"
  type        = string
  default     = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-api:latest"
}

variable "classifier_image" {
  description = "Docker image for Classifier API"
  type        = string
  default     = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-classifier:latest"
}

# ─── Cloud Run — Spring Boot ─────────────────────────────────────────────
variable "springboot_service_name" {
  description = "Cloud Run service name for Spring Boot"
  type        = string
  default     = "aeromontek-api"
}

variable "springboot_cpu" {
  description = "CPU limit for Spring Boot (e.g., '1' or '1000m')"
  type        = string
  default     = "1"
}

variable "springboot_memory" {
  description = "Memory limit in Gi for Spring Boot"
  type        = number
  default     = 1
}

variable "springboot_concurrency" {
  description = "Max concurrent requests per Spring Boot instance"
  type        = number
  default     = 40
}

variable "springboot_min_instances" {
  description = "Minimum instances for Spring Boot"
  type        = number
  default     = 0
}

variable "springboot_max_instances" {
  description = "Maximum instances for Spring Boot. Starter tier: 10 (cost cap)."
  type        = number
  default     = 10
}

# ─── Cloud Run — Classifier ──────────────────────────────────────────────
variable "classifier_service_name" {
  description = "Cloud Run service name for Classifier"
  type        = string
  default     = "aeromontek-classifier"
}

variable "classifier_cpu" {
  description = "CPU limit for Classifier"
  type        = string
  default     = "2"
}

variable "classifier_memory" {
  description = "Memory limit in Gi for Classifier"
  type        = number
  default     = 2
}

variable "classifier_concurrency" {
  description = "Max concurrent requests per Classifier instance"
  type        = number
  default     = 5
}

variable "classifier_min_instances" {
  description = "Minimum instances for Classifier (0 = scale to zero, 1+ = always warm)"
  type        = number
  default     = 0
}

variable "classifier_max_instances" {
  description = "Maximum instances for Classifier. Spec: 0..12 (CLOUD_READY_DESIGN §13.1)."
  type        = number
  default     = 12
}

variable "classifier_max_workers" {
  description = "MAX_WORKERS — parallel documents per Pub/Sub message within one instance"
  type        = string
  default     = "5"
}

variable "classifier_extraction_workers" {
  description = "MAX_EXTRACTION_WORKERS — threads in EXTRACTION_POOL per instance"
  type        = string
  default     = "10"
}

variable "classifier_classification_workers" {
  description = "MAX_CLASSIFICATION_WORKERS — threads in CLASSIFICATION_POOL per instance"
  type        = string
  default     = "10"
}

variable "classifier_flow_control_max_messages" {
  description = "FLOW_CONTROL_MAX_MESSAGES — max in-flight Pub/Sub messages per instance"
  type        = string
  default     = "10"
}

variable "classifier_chroma_snapshot_bucket" {
  description = "GCS bucket for ChromaDB snapshots (prevents re-embedding on cold start)"
  type        = string
  default     = ""   # Falls back to GCS_BUCKET if set; empty = no GCS persistence
}

# ─── CORS (Centralized — shared by Spring Boot API + Classifier) ────────
variable "cors_allowed_origins" {
  description = "Comma-separated CORS origins. Passed to both Cloud Run services via env var."
  type        = string
  default     = "https://synergy.zsds.io,https://zsynergy--zsynergy.us-east4.hosted.app,https://zsynergy.web.app,https://zsynergy.firebaseapp.com"
}

# ─── APIs ────────────────────────────────────────────────────────────────
variable "enabled_apis" {
  description = "List of Google APIs to enable"
  type        = list(string)
  default = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "apphosting.googleapis.com",
    "firebase.googleapis.com",
    "firestore.googleapis.com",
    "cloudkms.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "errorreporting.googleapis.com",
    "cloudtrace.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "compute.googleapis.com",
  ]
}

# ─── Secrets ─────────────────────────────────────────────────────────────
variable "secret_names" {
  description = "Names of Secret Manager secrets to create"
  type        = list(string)
  default = [
    "aeromon-firebase-api-key",
    "aeromon-openai-api-key",
    "aeromon-gemini-api-key",
    "aeromon-hf-token",
    "aeromon-db-password",
    "aeromon-firebase-admin-sa",
  ]
}

# ─── Monitoring / Alerting ──────────────────────────────────────────────
variable "alert_email_recipients" {
  description = "Email addresses that receive DLQ + reliability alerts. Leave [] to skip alert wiring."
  type        = list(string)
  default     = []
}

variable "alert_dlq_depth_threshold" {
  description = "DLQ depth that triggers an alert (sustained for window)."
  type        = number
  default     = 1
}

variable "alert_dlq_window_seconds" {
  description = "Sustained-window for DLQ-depth alert."
  type        = number
  default     = 300
}

# ─── Pub/Sub ─────────────────────────────────────────────────────────────
variable "pubsub_topics" {
  description = "Pub/Sub topics to create"
  type        = list(string)
  default = [
    "document-classification-request",
    "document-classification-request-dlq",
    "document-classification-result",
    "document-classification-result-dlq",
    "document-classification-progress",
    "document-classification-progress-dlq",
    "storage-finalize-events",
    "invoice-events",
    "email-outbox",
    "email-outbox-dlq",
  ]
}

variable "dlq_topic_names" {
  description = "Subset of pubsub_topics that are DLQs — used to wire alerts."
  type        = list(string)
  default = [
    "document-classification-request-dlq",
    "document-classification-result-dlq",
    "document-classification-progress-dlq",
    "email-outbox-dlq",
  ]
}

variable "classifier_push_endpoint_url" {
  description = <<-EOT
    HTTPS URL for Pub/Sub push delivery to the classifier, e.g.
    "https://classifier-abc-uk.a.run.app/pubsub/push".
    Set this after the first Cloud Run deploy when the service URL is known.
    When empty (default), a pull subscription is used — safe for initial deploy.
  EOT
  type    = string
  default = ""
}

variable "pubsub_retention_duration" {
  description = "Message retention duration for Pub/Sub topics"
  type        = string
  default     = "604800s" # 7 days
}

# ─── Cloud Build Trigger (CI/CD) ─────────────────────────────────────────
variable "github_owner" {
  description = "GitHub repository owner"
  type        = string
  default     = "zsds"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "gcp-builds"
}

variable "github_branch" {
  description = "GitHub branch to trigger builds on"
  type        = string
  default     = "main"
}

# =============================================================================
# Aviation Reference Data
# =============================================================================
variable "reference_refresh_cron" {
  description = "Cloud Scheduler cron for weekly reference data refresh. Default: Sunday 3 AM UTC."
  type        = string
  default     = "0 3 * * 0"
}
