# =============================================================================
# vars/zsynergy.tfvars — ZSynergy / AeroMontek Terraform Variables (Production)
# =============================================================================
# Usage:
#   terraform plan -var-file="vars/zsynergy.tfvars"
#   terraform apply -var-file="vars/zsynergy.tfvars"
# =============================================================================

project_id    = "zsynergy"
region        = "us-east4"
repo_location = "us"
repo_name     = "zsynergy"
sa_prefix     = "zsds-sa"

# ─── VPC & Networking ──────────────────────────────────────────────────────
vpc_name                = "aeromontek-vpc"
springboot_subnet_cidr  = "10.10.0.0/24"
classifier_subnet_cidr  = "10.10.1.0/24"
private_svc_subnet_cidr = "10.10.2.0/24"

# ─── Cloud SQL ──────────────────────────────────────────────────────────────
cloud_sql_instance_name = "zsynergy-pg"
cloud_sql_database      = "zsynergy"
cloud_sql_user          = "appuser"
cloud_sql_tier          = "db-g1-small"
cloud_sql_version       = "POSTGRES_15"

# ─── Storage Buckets ────────────────────────────────────────────────────────
documents_bucket_name = "zsynergy-documents"
uploads_bucket_name   = "zsynergy-uploads"

# ─── Component Toggles ───────────────────────────────────────────────────
enable_artifact_registry  = true
enable_frontend           = true
enable_springboot         = true
enable_classifier         = true
enable_firebase_functions = true
enable_eventarc           = true
enable_cloudbuild_trigger = false

# ─── Container Images (update after Cloud Build) ────────────────────────
springboot_image = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-api:latest"
classifier_image = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-classifier:latest"

# ─── Cloud Run — Spring Boot ─────────────────────────────────────────────
springboot_service_name  = "aeromontek-api"
springboot_cpu           = "1"
springboot_memory        = 1
springboot_concurrency   = 40
springboot_min_instances = 0
springboot_max_instances = 10

# ─── Cloud Run — Classifier ──────────────────────────────────────────────
classifier_service_name  = "aeromontek-classifier"
classifier_cpu           = "2"
classifier_memory        = 2
classifier_concurrency   = 5
classifier_min_instances = 0
classifier_max_instances = 10

# ─── Cloud Build Trigger (optional) ──────────────────────────────────────
github_owner  = "zsds"
github_repo   = "gcp-builds"
github_branch = "main"
