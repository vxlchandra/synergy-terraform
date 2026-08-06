# =============================================================================
# officesvc.tf — Office/email → PDF conversion for the document viewer
# =============================================================================
#
# AUTHORED, NOT APPLIED. `enable_officesvc` defaults to FALSE, so a plan against
# existing state is a no-op until an operator opts in — and until the image
# actually exists in Artifact Registry, since a service pointed at a missing
# image fails to start.
#
# WHEN YOU APPLY THIS, FLIP THE DEFAULT TO TRUE IN THE SAME CHANGE.
# `terraform.tfvars` is gitignored. A resource applied while its enable flag
# defaults to false is a resource that a clean checkout plans to DESTROY. That
# is not hypothetical: on 2026-07-31 a plan from a clean checkout proposed
# destroying the LIVE graphsvc service and its SA for exactly this reason.
# `enable_rastersvc` says "TRUE because it is applied" for the same reason.
#
# WHY A SEPARATE SERVICE FROM rastersvc. LibreOffice is ~450MB and slow to
# start. Rendering is lazy, so the FIRST viewer open pays the cold start;
# folding this into rastersvc would make opening a 2-page PDF wait on an office
# suite it never uses. rastersvc's cold start stays in seconds.
#
# WHAT THIS SERVICE DOES NOT DO. It renders nothing. It returns a PDF and
# rastersvc rasterizes it through the PDF path that already works — one set of
# canonical render parameters, one thing an annotation can anchor to.

# --- Service Account ---------------------------------------------------------
resource "google_service_account" "officesvc" {
  count        = var.enable_officesvc ? 1 : 0
  account_id   = "${var.sa_prefix}-officesvc"
  display_name = "ZSDS officesvc (document conversion) Service Account"
  project      = var.project_id
}

# --- IAM roles ---------------------------------------------------------------
# Reads the original document, writes the converted PDF under _converted/.
# objectViewer + objectCreator and NO delete, matching rastersvc: a converter
# that cannot delete cannot destroy a customer's source document, whatever a
# bug or a crafted object path asks it to do.
resource "google_project_iam_member" "officesvc_storage_viewer" {
  count   = var.enable_officesvc ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.officesvc[0].email}"
}

resource "google_project_iam_member" "officesvc_storage_creator" {
  count   = var.enable_officesvc ? 1 : 0
  project = var.project_id
  role    = "roles/storage.objectCreator"
  member  = "serviceAccount:${google_service_account.officesvc[0].email}"
}

resource "google_project_iam_member" "officesvc_logging" {
  count   = var.enable_officesvc ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.officesvc[0].email}"
}

# --- Cloud Run service -------------------------------------------------------
resource "google_cloud_run_v2_service" "officesvc" {
  count    = var.enable_officesvc ? 1 : 0
  name     = var.officesvc_service_name
  location = var.region
  project  = var.project_id

  # The deploy owns image, env and scaling at runtime; Terraform owns the
  # service's existence, identity and who may invoke it. Same split as rastersvc.
  lifecycle {
    ignore_changes = all

    # DO NOT REMOVE. See the header: a gitignored tfvars plus a false default is
    # how a live service gets silently destroyed. This converts that into a hard
    # error.
    prevent_destroy = true
  }

  template {
    service_account = google_service_account.officesvc[0].email

    containers {
      image = var.officesvc_image

      ports {
        container_port = 8080
      }

      resources {
        # DEFAULT CPU allocation (throttled outside a request), unlike rastersvc.
        # rastersvc needs always-allocated CPU because it finishes long documents
        # in a BackgroundTasks callback. Conversion here is entirely synchronous
        # inside the request, so there is no post-response work to starve, and
        # always-on CPU would bill for idle.
        cpu_idle = true

        # LibreOffice's first start dominates the latency a user sees on the
        # first Office document.
        startup_cpu_boost = true

        limits = {
          cpu    = var.officesvc_cpu
          memory = "${var.officesvc_memory}Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }

      # Per-conversion ceiling. LibreOffice can hang on a malformed document,
      # and a hung conversion holds the single worker until something kills it.
      env {
        name  = "OFFICE_CONVERT_TIMEOUT"
        value = tostring(var.officesvc_convert_timeout)
      }
    }

    scaling {
      min_instance_count = var.officesvc_min_instances
      max_instance_count = var.officesvc_max_instances
    }

    # ONE request per instance. A conversion is a CPU-bound `soffice` subprocess;
    # two on one instance contend for the same cores and each gets slower. Cloud
    # Run scales by adding instances.
    max_instance_request_concurrency = var.officesvc_concurrency

    # Measured on the real corpus: 4-10s typical, and a 348-page spreadsheet sits
    # at the top of that. This is headroom over the per-conversion timeout above,
    # not a target.
    timeout = "600s"

    # No vpc_access block: officesvc talks only to GCS, over Google's network.

    labels = {
      app       = "aeromontek"
      component = "officesvc"
      tier      = "backend"
    }
  }

  # Internal-only. Nothing outside the platform has any reason to reach a
  # document converter, and the browser must not.
  ingress      = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  launch_stage = "GA"
}

# --- Cloud Run IAM — who may invoke officesvc --------------------------------
# ONE binding: rastersvc, and nothing else. The Spring API deliberately gets
# nothing — it calls rastersvc, which decides whether a conversion is needed.
# Granting the API a direct path would be a second way to reach the converter
# that no code uses.
resource "google_cloud_run_v2_service_iam_member" "rastersvc_invokes_officesvc" {
  count    = var.enable_officesvc && var.enable_rastersvc ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.officesvc[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.rastersvc[0].email}"
}

# --- Outputs -----------------------------------------------------------------
output "officesvc_url" {
  description = "officesvc Cloud Run URL — set this as OFFICE_SVC_URL on rastersvc; it is also the OIDC audience."
  value       = var.enable_officesvc ? google_cloud_run_v2_service.officesvc[0].uri : "disabled"
}

output "officesvc_service_account" {
  description = "officesvc runtime service account email."
  value       = var.enable_officesvc ? google_service_account.officesvc[0].email : "disabled"
}
