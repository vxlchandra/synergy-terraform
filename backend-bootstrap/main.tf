# =============================================================================
# backend-bootstrap/main.tf — One-time: create the GCS bucket for Terraform state
# =============================================================================
#
# Usage:
#   cd terraform/backend-bootstrap
#   terraform init
#   terraform apply -var="project_id=zsynergy"
#
# After this succeeds, uncomment the backend "gcs" block in ../main.tf
# and run `terraform init -migrate-state` from the parent directory.
# =============================================================================

variable "project_id" {
  type    = string
  default = "zsynergy"
}

variable "region" {
  type    = string
  default = "us-east4"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "terraform_state" {
  name     = "zsds-terraform-state"
  project  = var.project_id
  location = var.region

  # Prevent accidental deletion
  force_destroy = false

  # Versioning — required for state file recovery
  versioning {
    enabled = true
  }

  # Uniform bucket-level access — no per-object ACLs
  uniform_bucket_level_access = true

  # Lifecycle: keep 30 versions, auto-delete noncurrent after 90 days
  lifecycle_rule {
    condition {
      num_newer_versions = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age                   = 90
      with_state            = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    app       = "aeromontek"
    component = "terraform-state"
    managed   = "bootstrap"
  }
}

output "bucket_name" {
  value = google_storage_bucket.terraform_state.name
}

output "bucket_url" {
  value = google_storage_bucket.terraform_state.url
}
