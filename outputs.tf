# =============================================================================
# outputs.tf — ZSynergy / AeroMontek Terraform Outputs
# =============================================================================

# ─── Artifact Registry ───────────────────────────────────────────────────
output "artifact_registry_uri" {
  description = "Artifact Registry Docker repository URI"
  value       = var.enable_artifact_registry ? google_artifact_registry_repository.docker_repo[0].name : "disabled"
}

# ─── Service Accounts ────────────────────────────────────────────────────
output "sa_frontend_email" {
  description = "Frontend service account email"
  value       = var.enable_frontend ? google_service_account.frontend[0].email : "disabled"
}

output "sa_springboot_email" {
  description = "Spring Boot service account email"
  value       = var.enable_springboot ? google_service_account.springboot[0].email : "disabled"
}

output "sa_classifier_email" {
  description = "Classifier service account email"
  value       = var.enable_classifier ? google_service_account.classifier[0].email : "disabled"
}

# ─── Cloud Run Services ──────────────────────────────────────────────────
output "springboot_service_url" {
  description = "Spring Boot API Cloud Run service URL"
  value       = var.enable_springboot ? google_cloud_run_v2_service.springboot[0].uri : "disabled"
}

output "springboot_service_name" {
  description = "Spring Boot API Cloud Run service name"
  value       = var.enable_springboot ? google_cloud_run_v2_service.springboot[0].name : "disabled"
}

output "classifier_service_url" {
  description = "Classifier API Cloud Run service URL"
  value       = var.enable_classifier ? google_cloud_run_v2_service.classifier[0].uri : "disabled"
}

output "classifier_service_name" {
  description = "Classifier API Cloud Run service name"
  value       = var.enable_classifier ? google_cloud_run_v2_service.classifier[0].name : "disabled"
}

# ─── Pub/Sub Topics ──────────────────────────────────────────────────────
output "pubsub_topic_ids" {
  description = "Pub/Sub topic IDs"
  value       = { for k, v in google_pubsub_topic.topics : k => v.id }
}

output "pubsub_subscription_ids" {
  description = "Pub/Sub subscription IDs"
  value = {
    classifier_request  = var.enable_classifier ? google_pubsub_subscription.classifier_request_sub[0].id : "disabled"
    result_springboot   = var.enable_springboot ? google_pubsub_subscription.result_springboot_sub[0].id : "disabled"
    progress_firebase   = var.enable_firebase_functions ? google_pubsub_subscription.progress_firebase_sub[0].id : "disabled"
  }
}

# ─── EventArc Triggers ───────────────────────────────────────────────────
output "eventarc_trigger_springboot" {
  description = "EventArc trigger for Spring Boot storage events"
  value       = var.enable_eventarc && var.enable_springboot ? google_eventarc_trigger.storage_springboot[0].name : "disabled"
}

output "eventarc_trigger_classifier" {
  description = "EventArc trigger for Classifier storage events"
  value       = var.enable_eventarc && var.enable_classifier ? google_eventarc_trigger.storage_classifier[0].name : "disabled"
}

# ─── Secret Manager ──────────────────────────────────────────────────────
output "secret_ids" {
  description = "Secret Manager secret IDs"
  value       = { for k, v in google_secret_manager_secret.secrets : k => v.id }
}

# ─── Cloud Build Trigger ─────────────────────────────────────────────────
output "cloudbuild_trigger_id" {
  description = "Cloud Build CI/CD trigger ID"
  value       = var.enable_cloudbuild_trigger ? google_cloudbuild_trigger.main_trigger[0].id : "disabled"
}

# ─── IAM Summary ─────────────────────────────────────────────────────────
output "iam_summary" {
  description = "Summary of service account role assignments"
  value = {
    frontend = var.enable_frontend ? google_service_account.frontend[0].email : "disabled"
    frontend_roles = [
      "roles/run.invoker",
    ]
    springboot = var.enable_springboot ? google_service_account.springboot[0].email : "disabled"
    springboot_roles = [
      "roles/cloudsql.client",
      "roles/pubsub.publisher",
      "roles/pubsub.subscriber",
      "roles/storage.objectViewer",
      "roles/datastore.user",
      "roles/secretmanager.secretAccessor",
    ]
    classifier = var.enable_classifier ? google_service_account.classifier[0].email : "disabled"
    classifier_roles = [
      "roles/pubsub.publisher",
      "roles/pubsub.subscriber",
      "roles/storage.objectViewer",
      "roles/datastore.user",
      "roles/logging.logWriter",
      "roles/secretmanager.secretAccessor",
    ]
  }
}
