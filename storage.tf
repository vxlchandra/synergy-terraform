# =============================================================================
# storage.tf — GCS Buckets and Pub/Sub Notifications
# =============================================================================

# Documents bucket
resource "google_storage_bucket" "documents" {
  name          = var.documents_bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  labels = {
    app       = "aeromontek"
    component = "storage"
    purpose   = "documents"
  }
}

# Uploads bucket
resource "google_storage_bucket" "uploads" {
  name          = var.uploads_bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }

  # Keep 3 versions of uploads (less than documents — uploads are transient)
  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    app       = "aeromontek"
    component = "storage"
    purpose   = "uploads"
  }
}

# GCS notification: documents bucket finalize events → Pub/Sub topic
resource "google_storage_notification" "documents_finalize" {
  bucket         = google_storage_bucket.documents.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.topics["storage-finalize-events"].id
  event_types    = ["OBJECT_FINALIZE"]

  depends_on = [google_pubsub_topic_iam_member.gcs_publish]
}

# GCS service account → allow publishing to Pub/Sub
resource "google_pubsub_topic_iam_member" "gcs_publish" {
  topic  = google_pubsub_topic.topics["storage-finalize-events"].id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-cloud-storage.iam.gserviceaccount.com"

  depends_on = [google_pubsub_topic.topics]
}

# Get current project for GCS service account reference
data "google_project" "current" {
  project_id = var.project_id
}
