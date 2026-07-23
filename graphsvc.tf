# =============================================================================
# graphsvc.tf — Apache AGE graph service (P4 of the pdf-classifier merge)
# =============================================================================
#
# AUTHORED, NOT APPLIED. `enable_graphsvc` defaults to false so a plan/apply on
# the existing state is a no-op until an operator flips it on. See
# classifier/infra/GRAPHSVC_DEPLOY.md for the human-confirmed apply runbook.
#
# ARCHITECTURE (locked 2026-07-19): Cloud SQL cannot host the Apache AGE
# extension, so Postgres+AGE runs INSIDE this scale-to-zero Cloud Run container.
# The graph is a DERIVED materialization, rebuilt on every cold start from the
# shared Cloud SQL source rows (KB ontology: 192 nodes / 614 edges — sub-second).
# Nothing graph-specific is persisted; scale-to-zero is safe because the graph
# always reconstructs from Cloud SQL truth. The "bridge into Cloud SQL" is the
# Cloud SQL connector below: private-IP / VPC egress + IAM roles/cloudsql.client,
# feeding the on-demand Layer-5 traceability graph builder. NO AGE objects are
# ever created on Cloud SQL — AGE lives only in the container's local Postgres.
#
# This file MIRRORS the classifier service (main.tf ~line 491): same VPC egress
# subnet, internal-load-balancer ingress, `lifecycle { ignore_changes = all }`
# (deploy scripts own runtime config), 600s timeout, and secret wiring.

# --- Service Account ---------------------------------------------------------
resource "google_service_account" "graphsvc" {
  count        = var.enable_graphsvc ? 1 : 0
  account_id   = "${var.sa_prefix}-graphsvc"
  display_name = "ZSDS AGE graphsvc Service Account"
  project      = var.project_id
}

# --- IAM roles (mirror the classifier SA's Cloud SQL wiring) -----------------
# Cloud SQL connector access so the graph builder can read source rows to rebuild
# the derived graph on cold start.
resource "google_project_iam_member" "graphsvc_cloudsql" {
  count   = var.enable_graphsvc ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.graphsvc[0].email}"
}

resource "google_project_iam_member" "graphsvc_logging" {
  count   = var.enable_graphsvc ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.graphsvc[0].email}"
}

# Read the shared Cloud SQL password secret (same secret the classifier uses).
resource "google_secret_manager_secret_iam_member" "graphsvc_db_password" {
  count     = var.enable_graphsvc ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets["aeromon-db-password"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.graphsvc[0].email}"
}

# --- Cloud Run service -------------------------------------------------------
resource "google_cloud_run_v2_service" "graphsvc" {
  count    = var.enable_graphsvc ? 1 : 0
  name     = var.graphsvc_service_name
  location = var.region
  project  = var.project_id

  # Managed by the deploy script, not Terraform. Ignore all drift — same pattern
  # as the classifier service (deploy owns image/env/scaling at runtime).
  lifecycle {
    ignore_changes = all
  }

  template {
    service_account = google_service_account.graphsvc[0].email

    containers {
      image = var.graphsvc_image

      ports {
        container_port = 8080
      }

      # Cloud SQL connector socket mount. The SHARED instance is public-IP only
      # (no private IP), so the graph source reader (graphsvc.app._source_conn_factory)
      # connects over /cloudsql/<conn>/.s.PGSQL.5432, NOT DB_HOST. This mount makes
      # that socket present. (Live service is imperatively managed —
      # `gcloud run services update --add-cloudsql-instances` — because of
      # lifecycle.ignore_changes below; this codifies it for recreation.)
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      resources {
        # Startup CPU boost shortens the cold-start graph rebuild (Postgres+AGE
        # start + loader.load_graph). In google provider v5+, startup_cpu_boost is
        # a `resources` argument (not a container-level one).
        startup_cpu_boost = true
        limits = {
          cpu    = var.graphsvc_cpu
          memory = "${var.graphsvc_memory}Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }

      # --- Cloud SQL bridge (source of truth for the derived graph) ----------
      # graphsvc reads these to reach the SHARED Cloud SQL instance via the
      # connector. NOTE: DATABASE_URL (the graphsvc app's own connection, per
      # classifier/config.py) is NOT set here — it points at the container-local
      # Postgres+AGE and is exported by the entrypoint (graphsvc-entrypoint.sh).
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

      # --- Graph feature flags ----------------------------------------------
      env {
        name  = "GRAPH_ENABLED"
        value = "true"
      }
      env {
        name  = "GRAPH_NAME"
        value = var.graphsvc_graph_name
      }
    }

    # Attach the SHARED Cloud SQL instance so its connector socket is mounted at
    # /cloudsql (see the container volume_mount above). Same instance the classifier
    # uses; graphsvc only READS the source `extractions` rows.
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.postgres.connection_name]
      }
    }

    scaling {
      min_instance_count = var.graphsvc_min_instances # 0 = scale-to-zero
      max_instance_count = var.graphsvc_max_instances
    }

    max_instance_request_concurrency = var.graphsvc_concurrency

    timeout = "600s"

    # Egress to Cloud SQL over the same subnet the classifier uses (private IP).
    vpc_access {
      network_interfaces {
        network    = google_compute_network.aeromontek_vpc.name
        subnetwork = google_compute_subnetwork.classifier_subnet.name
      }
      egress = "ALL_TRAFFIC"
    }

    labels = {
      app       = "aeromontek"
      component = "graphsvc"
      tier      = "backend"
    }
  }

  # Internal-only: reachable via the internal load balancer / VPC, invoked by the
  # Spring API SA and the Functions runtime SA over OIDC (bindings below).
  ingress      = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"
}

# --- Cloud Run IAM — who may invoke graphsvc ---------------------------------
# Spring Boot API SA invokes graphsvc (server-side graph queries).
resource "google_cloud_run_v2_service_iam_member" "springboot_invokes_graphsvc" {
  count    = var.enable_graphsvc && var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.graphsvc[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.springboot[0].email}"
}

# Classifier SA invokes graphsvc (GRAPH_ENABLED corroboration path, gated OFF
# until validated — see the design spec §P4).
resource "google_cloud_run_v2_service_iam_member" "classifier_invokes_graphsvc" {
  count    = var.enable_graphsvc && var.enable_classifier ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.graphsvc[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.classifier[0].email}"
}

# Firebase Functions runtime SA invokes graphsvc (the graphQuery callable proxies
# UI graph queries via OIDC). ASSUMPTION: gen2 Cloud Functions run as the Compute
# Engine default SA (<project-number>-compute@developer.gserviceaccount.com)
# unless overridden. Set var.functions_runtime_sa if a dedicated SA is used.
resource "google_cloud_run_v2_service_iam_member" "functions_invokes_graphsvc" {
  count    = var.enable_graphsvc && var.enable_firebase_functions ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.graphsvc[0].name
  role     = "roles/run.invoker"
  member   = var.functions_runtime_sa != "" ? "serviceAccount:${var.functions_runtime_sa}" : "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# --- Outputs -----------------------------------------------------------------
output "graphsvc_url" {
  description = "graphsvc Cloud Run URL (OIDC audience for the Functions callable / Spring client)."
  value       = var.enable_graphsvc ? google_cloud_run_v2_service.graphsvc[0].uri : "disabled"
}

output "graphsvc_service_account" {
  description = "graphsvc runtime service account email."
  value       = var.enable_graphsvc ? google_service_account.graphsvc[0].email : "disabled"
}
