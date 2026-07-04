# =============================================================================
# api-loadbalancer.tf — Global External ALB + Cloud Armor attachment (STAGED)
# =============================================================================
#
# Status: AUTHORED FOR REVIEW — NOT WIRED FOR CUTOVER.
#
# Gated behind var.enable_api_lb (default false), so a normal `terraform apply`
# creates NOTHING. To review the plan for this change:
#
#   terraform plan \
#     -var="enable_api_lb=true" \
#     -var="api_lb_domain=api.zsds.io"
#
# These resources are ADDITIVE: creating them does NOT disturb the existing
# App Hosting -> Cloud Run path. The Spring Boot service keeps its current
# ingress (INGRESS_TRAFFIC_ALL) so both paths work side-by-side.
#
# The actual CUTOVER is two deliberate, out-of-band steps (intentionally NOT in
# this file, so applying it can never break production routing):
#   1. Point DNS (var.api_lb_domain, A record) at the reserved IP emitted by the
#      `api_lb_ip_address` output. Wait for the managed cert to become ACTIVE.
#   2. Once the LB serves traffic through the WAF, tighten the Cloud Run service
#      ingress to INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER (main.tf:485) so the API
#      is reachable ONLY through Cloud Armor. Do this last, after (1) is proven.
#
# The WAF policy itself lives in cloudarmor.tf; it is attached below via the
# backend service's security_policy.
# =============================================================================

locals {
  # Only provision the LB when explicitly enabled AND the API service exists.
  api_lb_enabled = var.enable_api_lb && var.enable_springboot ? 1 : 0
}

# ─── Reserved global anycast IP for the external ALB ─────────────────────────
resource "google_compute_global_address" "api_lb" {
  count   = local.api_lb_enabled
  name    = "${var.springboot_service_name}-lb-ip"
  project = var.project_id
}

# ─── Serverless NEG -> Cloud Run (regional) ──────────────────────────────────
# References the service by name (not the count-gated resource) because the
# Cloud Run service is managed out-of-band by deploy_gcp.sh (ignore_changes=all).
resource "google_compute_region_network_endpoint_group" "api_serverless_neg" {
  count                 = local.api_lb_enabled
  name                  = "${var.springboot_service_name}-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.springboot_service_name
  }
}

# ─── Backend service with the Cloud Armor WAF policy attached ────────────────
# Serverless NEG backends take no health checks. Cloud Armor policies attach to
# EXTERNAL_MANAGED (global external ALB) backend services.
resource "google_compute_backend_service" "api_lb" {
  count                 = local.api_lb_enabled
  name                  = "${var.springboot_service_name}-backend"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.api_waf.id

  backend {
    group = google_compute_region_network_endpoint_group.api_serverless_neg[0].id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# ─── URL map ─────────────────────────────────────────────────────────────────
resource "google_compute_url_map" "api_lb" {
  count           = local.api_lb_enabled
  name            = "${var.springboot_service_name}-urlmap"
  project         = var.project_id
  default_service = google_compute_backend_service.api_lb[0].id
}

# ─── Google-managed SSL certificate ──────────────────────────────────────────
# Stays in PROVISIONING until var.api_lb_domain resolves to the reserved IP
# (cutover step 1). Harmless while provisioning.
resource "google_compute_managed_ssl_certificate" "api_lb" {
  count   = local.api_lb_enabled
  name    = "${var.springboot_service_name}-cert"
  project = var.project_id

  managed {
    domains = [var.api_lb_domain]
  }
}

# ─── Target HTTPS proxy ──────────────────────────────────────────────────────
resource "google_compute_target_https_proxy" "api_lb" {
  count            = local.api_lb_enabled
  name             = "${var.springboot_service_name}-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.api_lb[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.api_lb[0].id]
}

# ─── Global forwarding rule (:443) ───────────────────────────────────────────
resource "google_compute_global_forwarding_rule" "api_lb" {
  count                 = local.api_lb_enabled
  name                  = "${var.springboot_service_name}-fr"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.api_lb[0].id
  ip_address            = google_compute_global_address.api_lb[0].id
}
