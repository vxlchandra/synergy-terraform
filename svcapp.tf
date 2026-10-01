# =============================================================================
# svcapp.tf — the FastAPI service that owns POST /search
# =============================================================================
#
# AUTHORED, NOT APPLIED. `enable_svcapp` defaults to FALSE and NOTHING in this
# file exists in GCP yet: a plan from a clean checkout is a no-op, by design.
# This is the one case where a false default is correct — there is no live
# resource for it to propose destroying (contrast graphsvc/rastersvc/officesvc,
# where a false default plus a gitignored tfvars planned a DESTROY of a live
# service; see the header of officesvc.tf).
#
# READ THIS BEFORE ENABLING. The moment you apply with enable_svcapp = true,
# that trap becomes live for this service too. Flip the DEFAULT in variables.tf
# to true in the SAME change that enables it — do not rely on -var or a
# gitignored terraform.tfvars. `prevent_destroy` below is only the backstop that
# turns the mistake into a hard error.
#
# WHY THIS SERVICE EXISTS. aeromontek-api's HybridSearchService proxies
# POST /search. That route lives in the FastAPI app (classifier repo,
# src/svcapp/app.py). The deployed `aeromontek-classifier` runs the FLASK app
# (classify_api.py) and has no /search route at all — so hybrid search 404s
# today. This is the missing deployment, not a code fix.
#
# WHAT IT TALKS TO. The SHARED Cloud SQL instance, over the connector socket
# (/cloudsql), as a DEDICATED READ-ONLY login (svcapp_reader — cloudsql.tf).
# It reads the doc_chunks table: dense pgvector + lexical BM25, both filtered by
# tenant AND project. Nothing else. No provider/LLM egress: the embedder and the
# cross-encoder reranker are baked into the image and run locally
# (HF_HUB_OFFLINE=1), so this service needs no AI provider secret.
#
# Runbook: classifier/infra/SVCAPP_DEPLOY.md.
# Modelled on graphsvc.tf (the closest precedent: Cloud SQL connector + VPC
# egress + internal ingress + dedicated read-only DB login).

# --- Service Account ---------------------------------------------------------
resource "google_service_account" "svcapp" {
  count        = var.enable_svcapp ? 1 : 0
  account_id   = "${var.sa_prefix}-svcapp"
  display_name = "ZSDS svcapp (hybrid search) Service Account"
  project      = var.project_id
}

# --- IAM roles ---------------------------------------------------------------
# Cloud SQL connector access. This grants the ability to CONNECT; what the
# service may READ is decided by the Postgres role (svcapp_reader), not by IAM.
resource "google_project_iam_member" "svcapp_cloudsql" {
  count   = var.enable_svcapp ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.svcapp[0].email}"
}

resource "google_project_iam_member" "svcapp_logging" {
  count   = var.enable_svcapp ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.svcapp[0].email}"
}

# --- Secrets -----------------------------------------------------------------
# The shared internal-auth secret. It is NOT managed by this repo (it is absent
# from var.secret_names — see the note in classifier_phase_b.tf), so it is READ
# here rather than created: creating a same-named secret would either fail or,
# worse, produce a second secret whose value does not match what aeromontek-api
# sends, and every search would 401. Both the live classifier and the live API
# read `aeromon-internal-api-secret` today (verified against the deployed
# services), which is why svcapp must read the same one.
data "google_secret_manager_secret" "svcapp_internal_api_secret" {
  count     = var.enable_svcapp ? 1 : 0
  project   = var.project_id
  secret_id = var.svcapp_internal_secret_name
}

resource "google_secret_manager_secret_iam_member" "svcapp_internal_api_secret" {
  count     = var.enable_svcapp ? 1 : 0
  project   = var.project_id
  secret_id = data.google_secret_manager_secret.svcapp_internal_api_secret[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.svcapp[0].email}"
}

# svcapp's OWN read-only DB password (cloudsql.tf). Never the instance-owner
# credential: a compromised search service then reads one table instead of
# holding full read/write/DDL on the whole database.
resource "google_secret_manager_secret_iam_member" "svcapp_db_password" {
  count     = var.enable_svcapp ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.svcapp_db_password[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.svcapp[0].email}"
}

# --- Cloud Run service -------------------------------------------------------
resource "google_cloud_run_v2_service" "svcapp" {
  count    = var.enable_svcapp ? 1 : 0
  name     = var.svcapp_service_name
  location = var.region
  project  = var.project_id

  # The template references two secrets, but referencing a secret does not imply
  # the runtime SA may READ it. Without this, Terraform is free to create the
  # service before the accessor bindings exist, the first revision cannot mount
  # either secret, and the apply fails on a service that is already half-created.
  # Only an ordering constraint — no new resources, no IAM change.
  depends_on = [
    google_secret_manager_secret_iam_member.svcapp_db_password,
    google_secret_manager_secret_iam_member.svcapp_internal_api_secret,
    google_secret_manager_secret_version.svcapp_db_password,
  ]

  lifecycle {
    # Terraform owns the service's EXISTENCE, identity and who may invoke it;
    # the deploy (docker buildx build --push + `gcloud run services update`)
    # owns image/env/scaling at runtime. Same split as graphsvc/rastersvc/
    # officesvc — see SVCAPP_DEPLOY.md. CONSEQUENCE: everything in `template`
    # below is applied ONCE, at create. Changing an env var here later does NOT
    # reach the live service; an operator must run `gcloud run services update`.
    ignore_changes = all

    # DO NOT REMOVE. Inert while enable_svcapp is false (nothing in state). The
    # moment this is applied it becomes the backstop that turns "clean checkout
    # plans a destroy" into a hard error instead of a silent deletion.
    prevent_destroy = true
  }

  template {
    service_account = google_service_account.svcapp[0].email

    containers {
      image = var.svcapp_image

      ports {
        container_port = 8080
      }

      # Cloud SQL connector socket. The shared instance is PUBLIC-IP only, so
      # the connection goes over /cloudsql/<conn>/.s.PGSQL.5432 — DB_HOST is
      # deliberately NOT set (svcapp.dburl prefers the socket when both exist).
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      resources {
        # The embedder + cross-encoder load on the first search of a cold
        # instance; the boost is what keeps that inside the startup probe budget.
        startup_cpu_boost = true
        limits = {
          cpu    = var.svcapp_cpu
          memory = "${var.svcapp_memory}Gi"
        }
      }

      # --- Cloud SQL (composed into DATABASE_URL by the entrypoint) ----------
      # Cloud Run cannot interpolate a secret into another env var, so the URL is
      # assembled at boot from these — see classifier/src/svcapp/dburl.py
      # (percent-encoding is unit-tested; the prod password has URL-special
      # characters) and infra/svcapp-entrypoint.sh.
      env {
        name  = "CLOUD_SQL_CONNECTION_NAME"
        value = google_sql_database_instance.postgres.connection_name
      }
      env {
        name  = "DB_NAME"
        value = var.cloud_sql_database
      }
      env {
        name  = "DB_USER"
        value = "svcapp_reader"
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.svcapp_db_password[0].secret_id
            version = "latest"
          }
        }
      }

      # --- Internal auth ----------------------------------------------------
      # MANDATORY. svcapp's require_auth fails OPEN when neither
      # INTERNAL_API_SECRET nor SERVICE_API_KEY is set — it would serve /search,
      # /classify and /ingest unauthenticated and look healthy doing it. The
      # entrypoint refuses to start without one of them, so a missing value here
      # is a failed revision, not a silent hole. Cloud Run IAM (the single
      # invoker binding below) is the outer layer; this is the inner one.
      env {
        name = "INTERNAL_API_SECRET"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.svcapp_internal_api_secret[0].secret_id
            version = "latest"
          }
        }
      }

      # --- Bounds -----------------------------------------------------------
      # One pooled pg8000 connection per in-flight search; keep the pool and the
      # per-instance request concurrency equal so a saturated instance queues
      # instead of opening unbounded connections to the shared instance.
      env {
        name  = "DB_POOL_SIZE"
        value = tostring(var.svcapp_concurrency)
      }
      # Upper bound on top_k (svcapp rejects anything outside [1, this] with a
      # 400). Mirrors the app default; pinned here so it is visible in the plan.
      env {
        name  = "SEARCH_MAX_TOP_K"
        value = tostring(var.svcapp_max_top_k)
      }

      # --- Probes -----------------------------------------------------------
      # /readyz loads BOTH local models from the baked cache and fails closed
      # (503) if they cannot load offline, so it is the honest readiness signal:
      # an instance that passes it can actually answer a search. The budget
      # (18 x 10s = 180s) matches the classifier's documented cold-start budget.
      startup_probe {
        http_get {
          path = "/readyz"
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        timeout_seconds       = 5
        failure_threshold     = 18
      }

      # Liveness is /healthz (process up), NOT /readyz: a slow model load or a
      # saturated DB pool must not get a healthy instance killed and restarted.
      liveness_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.postgres.connection_name]
      }
    }

    scaling {
      min_instance_count = var.svcapp_min_instances
      max_instance_count = var.svcapp_max_instances
    }

    max_instance_request_concurrency = var.svcapp_concurrency

    # A search is seconds, not minutes; this is headroom over the API-side
    # 30s client timeout in HybridSearchService, not a target.
    timeout = "120s"

    vpc_access {
      network_interfaces {
        network    = google_compute_network.aeromontek_vpc.name
        subnetwork = google_compute_subnetwork.classifier_subnet.name
      }
      egress = "ALL_TRAFFIC"
    }

    labels = {
      app       = "aeromontek"
      component = "svcapp"
      tier      = "backend"
    }
  }

  # Internal-only. The browser never reaches svcapp: it calls the Next.js proxy,
  # which calls the Spring API, which calls this.
  ingress      = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"
}

# --- Cloud Run IAM — who may invoke svcapp -----------------------------------
# ONE binding: the Spring API's service account, and nothing else. It is the only
# caller in the codebase (HybridSearchService). The classifier and the Functions
# runtime deliberately get nothing — an unused second path into a service that
# can read every tenant's chunks is a liability, not convenience.
resource "google_cloud_run_v2_service_iam_member" "springboot_invokes_svcapp" {
  count    = var.enable_svcapp && var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.svcapp[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.springboot[0].email}"
}

# --- Outputs -----------------------------------------------------------------
output "svcapp_url" {
  description = "svcapp Cloud Run URL — set this as SVCAPP_BASE_URL on aeromontek-api; it is also the OIDC audience."
  value       = var.enable_svcapp ? google_cloud_run_v2_service.svcapp[0].uri : "disabled"
}

output "svcapp_service_account" {
  description = "svcapp runtime service account email."
  value       = var.enable_svcapp ? google_service_account.svcapp[0].email : "disabled"
}
