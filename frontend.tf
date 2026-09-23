# =============================================================================
# frontend.tf — aeromontek Next.js frontend on Cloud Run
# =============================================================================
#
# AUTHORED, NOT APPLIED. `enable_frontend_cloudrun` defaults to FALSE, so a
# plan against existing state is a no-op until an operator opts in — and
# until the image actually exists in Artifact Registry (built by the new
# `frontend-deploy` step in the root cloudbuild.yaml), since a service pointed
# at a missing image fails to start.
#
# WHEN YOU APPLY THIS, FLIP THE DEFAULT TO TRUE IN THE SAME CHANGE.
# `terraform.tfvars` is gitignored. A resource applied while its enable flag
# defaults to false is a resource that a clean checkout plans to DESTROY. That
# is not hypothetical: on 2026-07-31 a plan from a clean checkout proposed
# destroying the LIVE graphsvc service and its SA for exactly this reason (see
# officesvc.tf for the same note against that same incident).
#
# Deliberately a SEPARATE flag from `enable_frontend`, which already gates the
# frontend service account + its IAM grants in main.tf and is already TRUE in
# production (that SA exists and is idle today, granted only roles/run.invoker
# on the Spring Boot and classifier services). This flag gates only the NEW
# Cloud Run service itself and its public-invoker binding below.
#
# WHY THIS EXISTS. The frontend has deployed via Firebase App Hosting, whose
# Cloud Build job has no `machineType` set and therefore runs on the default
# E2_MEDIUM (2 vCPU / 4GB RAM) — too small for this app's `next build`
# (output: 'standalone', 68 routes, a genkit-powered AI search route that
# alone needs to trace ~5,858 files of firebase-admin/gRPC/protobuf/
# OpenTelemetry). App Hosting exposes no way to request a bigger build
# machine. Verified end-to-end on 2026-09-23: the identical source builds
# cleanly in 6 minutes on Cloud Build's E2_HIGHCPU_8 (8 vCPU / 8GB RAM) with a
# correctly-sized heap — zero code changes needed once given adequate memory.
# Cloud Run's own Cloud Build pipeline (already E2_HIGHCPU_8 for the Java
# suite) lets this app's build actually finish. See the root cloudbuild.yaml's
# `frontend-build`/`frontend-docker`/`frontend-push` steps (image built from
# `aeromontek/Dockerfile.cloudrun`) and the new `frontend-deploy` step that
# creates/updates this service.
#
# Public traffic today (synergy.zsds.io) is bound directly to the Firebase App
# Hosting backend via Firebase's own domain-binding feature, NOT a
# Terraform-managed DNS/LB resource — cutting synergy.zsds.io over to this
# Cloud Run service is a deliberate, separate decision (domain mapping vs. a
# GCLB mirroring api-loadbalancer.tf's staged pattern), not part of standing
# this service up. Until that decision is made, this service is reachable only
# on its own Cloud Run `*.run.app` URL, with zero effect on production
# traffic.

resource "google_cloud_run_v2_service" "frontend" {
  count    = var.enable_frontend && var.enable_frontend_cloudrun ? 1 : 0
  name     = var.frontend_service_name
  location = var.region
  project  = var.project_id

  # The deploy owns image, env and scaling at runtime; Terraform owns the
  # service's existence, identity and who may invoke it. Same split as
  # springboot/classifier/officesvc.
  lifecycle {
    ignore_changes = all

    # DO NOT REMOVE. See the header: a gitignored tfvars plus a false default
    # is how a live service gets silently destroyed. This converts that into
    # a hard error.
    prevent_destroy = true
  }

  template {
    service_account = google_service_account.frontend[0].email

    containers {
      image = var.frontend_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.frontend_cpu
          memory = "${var.frontend_memory}Gi"
        }
      }

      # Minimal bootstrap set for the very first `terraform apply`, before
      # any real deploy has run. What actually makes the container start
      # and pass Cloud Run's startup probe is the Dockerfile's own
      # ENV PORT=8080 / HOSTNAME=0.0.0.0 plus the Next.js standalone server
      # binding to that port — independent of these two vars. The real
      # ~38-variable apphosting.yaml-equivalent config (Firebase public
      # config, API endpoint paths, BACKEND_API_URL secret, etc.) is applied
      # by the frontend-deploy step's --update-env-vars/--update-secrets,
      # which is NOT reverted by the ignore_changes = all above.
      env {
        name  = "NODE_ENV"
        value = "production"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
    }

    scaling {
      min_instance_count = var.frontend_min_instances
      max_instance_count = var.frontend_max_instances
    }

    max_instance_request_concurrency = var.frontend_concurrency

    timeout = "300s"

    # No vpc_access block: the frontend never talks to Cloud SQL directly —
    # only to the Spring Boot API over HTTPS (see frontend_invokes_springboot
    # / frontend_invokes_classifier in main.tf) and to Firebase over the
    # public internet.

    labels = {
      app       = "aeromontek"
      component = "frontend"
      tier      = "web"
    }
  }

  # Public — this is the app's actual entry point for end users, unlike
  # springboot/classifier which are reached server-to-server. App-layer auth
  # (Firebase Auth) is the real gate, same posture as springboot's own
  # ingress comment in main.tf.
  ingress = "INGRESS_TRAFFIC_ALL"

  launch_stage = "GA"
}

# --- Cloud Run IAM — who may invoke the frontend -----------------------------
# allUsers: real end-user browsers hit this service directly. Firebase Auth
# (client-side + ID-token verification in the Spring Boot API it proxies to)
# is the actual access-control gate, not Cloud Run invoker IAM — same posture
# `public_invokes_springboot` documents in main.tf for the equivalent
# App-Hosting-can't-issue-OIDC situation.
resource "google_cloud_run_v2_service_iam_member" "public_invokes_frontend" {
  count    = var.enable_frontend && var.enable_frontend_cloudrun ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.frontend[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Secret Manager IAM ------------------------------------------------------
# Adversarial review caught a real gap: without this grant, the gcp-builds
# frontend-deploy step's `--update-secrets=BACKEND_API_URL=aeromon-backend-
# api-url:latest` would be rejected by Cloud Run at the secret-mount
# permission check on every deploy. Referenced by literal secret_id, NOT
# via google_secret_manager_secret.secrets[...] -- that map is built from
# var.secret_names, and this specific secret is deliberately NOT in it: it
# is created out-of-band, imperatively, by cloudbuild.yaml's deploy-
# springboot step (`gcloud secrets create aeromon-backend-api-url` on first
# run). Referencing it as a Terraform-managed google_secret_manager_secret
# resource here would make the next `terraform apply` try to CREATE a
# secret that already exists in production. A plain literal secret_id
# string avoids that entirely -- this grants access to the existing secret
# without taking over its lifecycle.
resource "google_secret_manager_secret_iam_member" "frontend_backend_api_url" {
  count     = var.enable_frontend && var.enable_frontend_cloudrun ? 1 : 0
  project   = var.project_id
  secret_id = "aeromon-backend-api-url"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.frontend[0].email}"
}

# --- Outputs -----------------------------------------------------------------
output "frontend_cloudrun_url" {
  description = "Frontend Cloud Run URL (*.run.app) — verify end-to-end here BEFORE any synergy.zsds.io cutover decision."
  value       = var.enable_frontend_cloudrun ? google_cloud_run_v2_service.frontend[0].uri : "disabled"
}
