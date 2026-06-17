# =============================================================================
# firebase.tf — Firestore Database
# =============================================================================

# Firestore Database in Native mode.
# location_id is IMMUTABLE and the live (default) DB is the `nam5` multi-region
# — it must NOT track var.region (us-east4), or Terraform would force-replace and
# DESTROY all production data. prevent_destroy is a second hard guard.
resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.firestore_location
  type        = "FIRESTORE_NATIVE"

  lifecycle {
    prevent_destroy = true
  }
}

# Adopt the pre-existing production (default) Firestore DB into state (TF 1.5+).
import {
  to = google_firestore_database.default
  id = "projects/${var.project_id}/databases/(default)"
}
