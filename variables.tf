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
  description = "Maximum instances for Spring Boot"
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
  description = "Minimum instances for Classifier"
  type        = number
  default     = 0
}

variable "classifier_max_instances" {
  description = "Maximum instances for Classifier"
  type        = number
  default     = 10
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

# ─── Pub/Sub ─────────────────────────────────────────────────────────────
variable "pubsub_topics" {
  description = "Pub/Sub topics to create"
  type        = list(string)
  default = [
    "document-classification-request",
    "document-classification-result",
    "document-classification-progress",
    "storage-finalize-events",
    "invoice-events",
  ]
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
