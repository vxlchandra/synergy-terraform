# =============================================================================
# rastersvc.tf — page rasterization service for document viewer v1 (Spec E)
# =============================================================================
#
# AUTHORED, NOT APPLIED. `enable_rastersvc` defaults to false, so a plan/apply
# against existing state is a no-op until an operator opts in. Same posture as
# graphsvc.tf, which this file mirrors.
#
# WHY A SEPARATE SERVICE. The classifier runs at concurrency 5 and is already
# the platform's throughput bottleneck. Rasterizing a 400-page manual inside
# those instances would evict classification work. Same repository, different
# image (classifier/Dockerfile.rastersvc), different service, independent
# scaling.
#
# WHY THIS IS TERRAFORM AND NOT `gcloud run deploy --no-allow-unauthenticated`.
# The service and its `run.invoker` binding are infrastructure: reviewed as
# code, reproducible, and visible in state. A service created imperatively is
# invisible to `terraform plan` and the next apply fights it. `--no-allow-
# unauthenticated` is only the imperative spelling of "grant no binding to
# allUsers" — which is the default here, since the sole binding below names one
# service account.

# --- Service Account ---------------------------------------------------------
resource "google_service_account" "rastersvc" {
  count        = var.enable_rastersvc ? 1 : 0
  account_id   = "${var.sa_prefix}-rastersvc"
  display_name = "ZSDS rastersvc (page rasterization) Service Account"
  project      = var.project_id
}

# --- IAM roles ---------------------------------------------------------------
# Reads the original document, writes rendered pages under _rendered/. Mirrors
# the classifier's split deliberately: objectViewer (get + list) plus
# objectCreator (create; overwrite implicit) and NO delete. A renderer that
# cannot delete cannot destroy a customer's source document, whatever a bug or
# a crafted object path asks it to do. Rendered pages are expired by a bucket
# lifecycle rule, not by this service.
resource "google_project_iam_member" "rastersvc_storage_viewer" {
  count   = var.enable_rastersvc ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.rastersvc[0].email}"
}

resource "google_project_iam_member" "rastersvc_storage_creator" {
  count   = var.enable_rastersvc ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.rastersvc[0].email}"
}

resource "google_project_iam_member" "rastersvc_logging" {
  count   = var.enable_rastersvc ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.rastersvc[0].email}"
}

# --- Cloud Run service -------------------------------------------------------
resource "google_cloud_run_v2_service" "rastersvc" {
  count    = var.enable_rastersvc ? 1 : 0
  name     = var.rastersvc_service_name
  location = var.region
  project  = var.project_id

  # The deploy owns image, env and scaling at runtime; Terraform owns the
  # service's existence, identity and who may invoke it. Same split as graphsvc
  # and the classifier.
  lifecycle {
    ignore_changes = all

    # DO NOT REMOVE. `enable_rastersvc` defaults to false, and terraform.tfvars
    # is gitignored — so a checkout without it plans `count = 0` and silently
    # DESTROYS this service. That is not hypothetical: on 2026-07-31 a plan from
    # a clean checkout proposed destroying the LIVE graphsvc service and its SA
    # for exactly this reason. prevent_destroy converts that silent deletion into
    # a hard error. Tearing rastersvc down deliberately means editing this block
    # first — which is the point.
    prevent_destroy = true
  }

  template {
    service_account = google_service_account.rastersvc[0].email

    containers {
      image = var.rastersvc_image

      ports {
        container_port = 8080
      }

      resources {
        # ALWAYS-ALLOCATED CPU, deliberately. /render returns after the first
        # RASTER_SYNC_PAGES pages and finishes the rest in a FastAPI
        # BackgroundTasks callback (rastersvc/app.py:164). Cloud Run throttles
        # CPU to near zero outside a request unless cpu_idle is false, so with
        # the default the background pages of a long document would crawl or
        # stall until some later request happened to wake the instance — and
        # the cache would sit permanently partial. CacheState.complete rejects
        # a partial render, so that failure mode is silent-but-slow rather than
        # wrong. Combined with min_instance_count = 0 the billed window is the
        # render plus the idle timeout, not the day.
        cpu_idle = false

        # Shortens the cold start a lazy first render pays, in the user's view.
        startup_cpu_boost = true

        limits = {
          cpu    = var.rastersvc_cpu
          memory = "${var.rastersvc_memory}Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }

      # Pages rendered before /render responds. The rest continue in the
      # background task above.
      env {
        name  = "RASTER_SYNC_PAGES"
        value = tostring(var.rastersvc_sync_pages)
      }

      # Hard ceiling on pages per document. A bound, not a tuning knob: without
      # it one pathological upload can occupy an instance indefinitely.
      env {
        name  = "RASTER_MAX_PAGES"
        value = tostring(var.rastersvc_max_pages)
      }
    }

    scaling {
      min_instance_count = var.rastersvc_min_instances # 0 = scale-to-zero
      max_instance_count = var.rastersvc_max_instances
    }

    # Rendering is CPU-bound and the image runs a single uvicorn worker, so
    # concurrent requests on one instance contend for the same cores. Cloud Run
    # scales by adding instances; this stays low on purpose.
    max_instance_request_concurrency = var.rastersvc_concurrency

    # A long document's background render must outlive the response. This is the
    # instance's request timeout, not the sync path, which returns in ~1s.
    timeout = "900s"

    # No vpc_access block: rastersvc talks only to GCS, over Google's network.
    # graphsvc needs the VPC because it reaches Cloud SQL; adding a connector
    # here would buy nothing and add a failure mode.

    labels = {
      app       = "aeromontek"
      component = "rastersvc"
      tier      = "backend"
    }
  }

  # Internal-only. Nothing outside the platform has any reason to reach a
  # renderer, and the browser must not: it receives rendered pages through the
  # Spring API, which authorizes the document first.
  ingress      = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"
}

# --- Cloud Run IAM — who may invoke rastersvc --------------------------------
# ONE binding, by design. graphsvc grants three because three services query the
# graph; rastersvc is called by the Spring API alone (RasterRenderClient), which
# has already run the document's authorization check. The classifier and the
# Functions runtime deliberately get nothing — an extra invoker here would be an
# extra path to rendered customer pages that no code needs.
resource "google_cloud_run_v2_service_iam_member" "springboot_invokes_rastersvc" {
  count    = var.enable_rastersvc && var.enable_springboot ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.rastersvc[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.springboot[0].email}"
}

# --- Outputs -----------------------------------------------------------------
output "rastersvc_url" {
  description = "rastersvc Cloud Run URL — the OIDC audience for the Spring RasterRenderClient."
  value       = var.enable_rastersvc ? google_cloud_run_v2_service.rastersvc[0].uri : "disabled"
}

output "rastersvc_service_account" {
  description = "rastersvc runtime service account email."
  value       = var.enable_rastersvc ? google_service_account.rastersvc[0].email : "disabled"
}
