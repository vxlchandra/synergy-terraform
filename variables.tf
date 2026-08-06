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
  description = "Database user for Cloud SQL. Matches the actual prod user (the instance owner the apps connect as); NOT 'appuser' — that name never existed in prod and setting it forces a destructive google_sql_user replacement + password reset."
  type        = string
  default     = "zsynergy"
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

variable "firestore_location" {
  description = "Firestore (default) DB location — IMMUTABLE. Live prod = nam5 multi-region."
  type        = string
  default     = "nam5"
}

# ─── Repositories ────────────────────────────────────────────────────────
variable "repo_name" {
  description = "Artifact Registry Docker repository name"
  type        = string
  default     = "zsynergy"
}

# ─── Artifact Registry Cleanup Policies (FinOps) ─────────────────────────
variable "ar_cleanup_keep_count" {
  description = "Most-recent versions ALWAYS kept per image. Must exceed deploys-between-redeploys so a live revision's (now-untagged) serving digest is never reaped. Default 20."
  type        = number
  default     = 20
}

variable "ar_cleanup_untagged_older_than" {
  description = "Delete UNTAGGED versions older than this. Must exceed the longest a service stays on one revision (serving digest goes untagged once :latest moves). Default 30d."
  type        = string
  default     = "2592000s" # 30d
}

variable "ar_cleanup_dry_run" {
  description = "When true, cleanup policies only LOG candidates and never delete"
  type        = bool
  default     = true
}

variable "enable_gcs_finalize_notification" {
  description = "Activate GCS documents-bucket OBJECT_FINALIZE → Pub/Sub notification + GCS publish grant. Default off: live pipeline uses Firestore doc-triggers; enabling risks double-processing."
  type        = bool
  default     = false
}

variable "manage_aeromontek_api_repo" {
  description = "Adopt the standalone aeromontek-api AR repo into Terraform (requires import)"
  type        = bool
  default     = true
}

variable "aeromontek_api_repo_location" {
  description = "Location of the standalone aeromontek-api AR repo"
  type        = string
  default     = "us-east4"
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

# ─── API Load Balancer + Cloud Armor (staged, see api-loadbalancer.tf) ───────
variable "enable_api_lb" {
  description = <<-EOT
  Provision the Global External ALB in front of the Spring Boot API with the
  Cloud Armor WAF attached. See api-loadbalancer.tf.

  DEFAULT FLIPPED false -> true ON 2026-08-02, in the same change that made it
  true in reality. The LB was APPLIED on that date (global IP 8.232.66.240,
  backend `aeromontek-api-backend` with policy `aeromontek-api-waf` attached).

  Leaving the default at false after applying is the documented `enable_*` trap:
  terraform.tfvars is gitignored, so a clean checkout would plan count = 0 for
  resources that exist and DESTROY them. For this stack that means releasing the
  global IP -- and a released global IP does not come back. Verify against
  `terraform state list` before ever flipping this to false.
  EOT
  type        = bool
  default     = true
}

variable "api_lb_domain" {
  description = "FQDN for the API load balancer's Google-managed SSL certificate. Required (non-empty) when enable_api_lb = true. Certificate stays PROVISIONING until this name resolves to the LB IP."
  type        = string
  default     = "api.zsds.io"
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
  default     = "" # Falls back to GCS_BUCKET if set; empty = no GCS persistence
}

# ─── Cloud Run — graphsvc (Apache AGE, P4) ───────────────────────────────
# APPLIED AND LIVE since 2026-07-23. This block used to read "authored, not
# applied" with default = false, and that stayed false after the apply.
#
# The result, found 2026-07-31: terraform.tfvars is gitignored (.gitignore:33),
# so a clean checkout evaluated enable_graphsvc = false, planned count = 0 for a
# service that exists, and proposed destroying the live graphsvc Cloud Run
# service, its service account, both project IAM bindings, the secret accessor
# binding and all three invoker bindings. Eight deletions, no warning louder
# than a plan line.
#
# The lesson is general: a default-OFF flag is honest only while the resource is
# genuinely unapplied. Once applied, the default must be flipped to true in the
# same change, or the flag silently becomes a delete instruction for anyone
# without the untracked tfvars. Verified against `terraform state list` before
# flipping — 8 graphsvc resources present.
variable "enable_graphsvc" {
  description = "Create the Apache AGE graphsvc Cloud Run service + its SA/IAM. TRUE because it is deployed and live — see the note above before changing."
  type        = bool
  default     = true
}

variable "graphsvc_service_name" {
  description = "Cloud Run service name for the AGE graph service"
  type        = string
  default     = "aeromontek-graphsvc"
}

variable "graphsvc_image" {
  description = "Docker image for graphsvc (combined Postgres+AGE + FastAPI). Built from classifier/infra/graphsvc.Dockerfile."
  type        = string
  default     = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-graphsvc:latest"
}

variable "graphsvc_cpu" {
  description = "CPU limit for graphsvc (Postgres+AGE + uvicorn in one container)"
  type        = string
  default     = "2"
}

variable "graphsvc_memory" {
  description = "Memory limit in Gi for graphsvc"
  type        = number
  default     = 2
}

variable "graphsvc_concurrency" {
  description = "Max concurrent requests per graphsvc instance (bounded pg8000 pool)"
  type        = number
  default     = 8
}

variable "graphsvc_min_instances" {
  description = "Minimum instances for graphsvc (0 = scale-to-zero; graph rebuilds on cold start)"
  type        = number
  default     = 0
}

variable "graphsvc_max_instances" {
  description = "Maximum instances for graphsvc"
  type        = number
  default     = 4
}

variable "graphsvc_graph_name" {
  description = "AGE graph name (matches classifier config GRAPH_NAME / load_graph default)"
  type        = string
  default     = "aviation_records_kg"
}

variable "functions_runtime_sa" {
  description = <<-EOT
    Email of the Firebase Functions gen2 runtime service account that invokes
    graphsvc over OIDC. Leave empty to fall back to the Compute Engine default
    SA (<project-number>-compute@developer.gserviceaccount.com). Set this if the
    functions codebase runs as a dedicated SA.
  EOT
  type        = string
  default     = ""
}

# ─── Cloud Run — rastersvc (page rasterization, Spec E) ──────────────────
# Authored, not applied. enable_rastersvc defaults false so nothing is created
# until an operator opts in (see terraform/rastersvc.tf).
#
# APPLIED 2026-07-31, and the default was flipped to true IN THE SAME CHANGE —
# which is precisely the step that was missed for graphsvc and left a live
# service one clean-checkout apply away from deletion. See the note on
# enable_graphsvc for what that costs.
variable "enable_rastersvc" {
  description = "Create the rastersvc Cloud Run service + its SA/IAM. TRUE because it is applied — see the note on enable_graphsvc before changing."
  type        = bool
  default     = true
}

variable "rastersvc_service_name" {
  description = "Cloud Run service name for the page rasterization service"
  type        = string
  default     = "aeromontek-rastersvc"
}

variable "rastersvc_image" {
  description = "Docker image for rastersvc. Built from classifier/Dockerfile.rastersvc."
  type        = string
  default     = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-rastersvc:latest"
}

variable "rastersvc_cpu" {
  description = "CPU limit for rastersvc. Rendering is CPU-bound; this is the knob that moves render latency."
  type        = string
  default     = "2"
}

variable "rastersvc_memory" {
  description = "Memory limit in Gi. PyMuPDF holds one page bitmap at a time (150 DPI, max edge 2000px), not the document."
  type        = number
  default     = 2
}

variable "rastersvc_concurrency" {
  description = "Max concurrent requests per instance. Low on purpose: one uvicorn worker, CPU-bound work, so extra requests contend for the same cores."
  type        = number
  default     = 4
}

variable "rastersvc_min_instances" {
  description = "Minimum instances (0 = scale-to-zero). Rendering is lazy and the feature is not yet enabled; a warm instance would bill for something nothing calls. Raise to 1 when the viewer ships and a cold start lands on a user."
  type        = number
  default     = 0
}

variable "rastersvc_max_instances" {
  description = "Maximum instances for rastersvc"
  type        = number
  default     = 10
}

variable "rastersvc_sync_pages" {
  description = "Pages rendered before /render responds; the rest continue in a background task. Must match RASTER_SYNC_PAGES in rastersvc/app.py."
  type        = number
  default     = 3
}

variable "rastersvc_max_pages" {
  description = "Hard ceiling on pages rendered per document. A bound against one pathological upload occupying an instance, not a tuning knob."
  type        = number
  default     = 500
}

variable "enable_officesvc" {
  description = "Create the officesvc Cloud Run service + its SA/IAM. FALSE because it is authored but NOT YET APPLIED — flip to true in the SAME change that applies it, or a clean checkout plans to destroy it (see the note in officesvc.tf)."
  type        = bool
  default     = false
}

variable "officesvc_service_name" {
  description = "Cloud Run service name for the document conversion service"
  type        = string
  default     = "aeromontek-officesvc"
}

variable "officesvc_image" {
  description = "Docker image for officesvc. Built from classifier/Dockerfile.officesvc."
  type        = string
  default     = "us-docker.pkg.dev/zsynergy/zsynergy/aeromontek-officesvc:latest"
}

variable "officesvc_cpu" {
  description = "CPU limit for officesvc. LibreOffice conversion is CPU-bound; this is the knob that moves conversion latency."
  type        = string
  default     = "2"
}

variable "officesvc_memory" {
  description = "Memory limit in Gi. Higher than rastersvc on purpose: LibreOffice holds the WHOLE document model in memory, not one page — a large deck or spreadsheet is the peak, and a real 348-page corpus spreadsheet is what set this."
  type        = number
  default     = 4
}

variable "officesvc_concurrency" {
  description = "Max concurrent requests per instance. ONE: a conversion is a CPU-bound soffice subprocess and two on an instance contend for the same cores."
  type        = number
  default     = 1
}

variable "officesvc_min_instances" {
  description = "Minimum instances (0 = scale-to-zero). LibreOffice's first start is slow, so 0 means the first Office document a user opens waits on a cold suite. Raise to 1 if that latency is felt."
  type        = number
  default     = 0
}

variable "officesvc_max_instances" {
  description = "Maximum instances for officesvc"
  type        = number
  default     = 5
}

variable "officesvc_convert_timeout" {
  description = "Seconds before one conversion is abandoned. LibreOffice can hang on a malformed document and would otherwise hold the single worker indefinitely. Must match OFFICE_CONVERT_TIMEOUT in officesvc/convert.py."
  type        = number
  default     = 180
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
    # NOT "apphosting.googleapis.com" — that service does not exist. The real name
    # is firebaseapphosting, and it is already ENABLED, so this line is a state
    # adoption, not a change. The wrong name has been in this list since the initial
    # commit and has never been adopted: every apply failed on it and left the other
    # 19 APIs enabled, which is why nobody noticed.
    "firebaseapphosting.googleapis.com",
    "firebase.googleapis.com",
    "firestore.googleapis.com",
    "cloudkms.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    # Same: the real name is clouderrorreporting.googleapis.com.
    "clouderrorreporting.googleapis.com",
    "cloudtrace.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "compute.googleapis.com",
    "cloudtasks.googleapis.com", # drive-file-transfers queue (T27, cloudtasks.tf)
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
  default = [
    "chandra@vxlllc.com",
    "synergy-admin-group@vxlllc.com",
    "synergy-ops-admin-group@vxlllc.com",
    "sales-zsds@zsds.io", # kept: terraform-managed "AeroMontek alerts →" channel exists in prod
  ]
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
  type        = string
  default     = ""
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

# ─── Cloud Tasks — drive-file-transfers queue (T27, cloudtasks.tf) ───────
variable "transfer_queue_max_concurrent_dispatches" {
  description = "Max simultaneously-running drive-file-transfers tasks (= concurrent Box connections from the transfer fan-out). Kept well under springboot_concurrency (40) x springboot_max_instances (10) = 400, and modest for Cloud NAT + Box API rate limits. Matches the live prod queue (20) to keep terraform zero-diff."
  type        = number
  default     = 20
}

variable "transfer_queue_max_dispatches_per_second" {
  description = "Max dispatch rate for the drive-file-transfers queue. Bounds burst rate against Box + Cloud NAT, well under Cloud Tasks' unbounded default (~500/s). Matches the live prod queue (10) to keep terraform zero-diff."
  type        = number
  default     = 10
}

variable "transfer_queue_max_attempts" {
  description = "Max delivery attempts for a drive-file-transfers task before Cloud Tasks gives up. MUST be >= the app's app.transfer.max-attempts (default 5, AppRuntimeProperties.Transfer.maxAttempts) so the app's own retry/DLQ classification (T24) is always the terminator, never the queue."
  type        = number
  default     = 5
}
