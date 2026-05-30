# =============================================================================
# cloudarmor.tf — Cloud Armor WAF Policy (Minimum Viable Protection)
# =============================================================================
#
# Protects Spring Boot API against DDoS and common web attacks.
# Uses standard-tier Cloud Armor (no Managed Protection Plus cost).
#
# DEPLOYMENT NOTE: This policy is created independently of a load balancer.
# To attach it to Cloud Run, you need:
#   1. Serverless NEG for the Cloud Run service
#   2. Backend Service with this security policy
#   3. URL Map + HTTPS Proxy + Forwarding Rule
# Until a Global LB is provisioned, this policy exists as a ready-to-attach
# resource. The max-instances cap on Cloud Run (10) limits cost exposure.
#
# Estimated cost: ~$5/mo (1 policy + 5 rules)
# =============================================================================

resource "google_compute_security_policy" "api_waf" {
  name        = "aeromontek-api-waf"
  description = "WAF policy for Spring Boot API — standard tier"
  project     = var.project_id

  # ─── Rule 1: Block known bad bots / scanners ──────────────────────────
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS attacks (OWASP CRS 3.3)"
  }

  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection attacks (OWASP CRS 3.3)"
  }

  # ─── Rule 2: Rate limiting per IP ─────────────────────────────────────
  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 300
        interval_sec = 60
      }
    }
    description = "Rate limit: 300 requests/min per IP"
  }

  # ─── Rule 3: Block large request bodies (>10 MB) ──────────────────────
  rule {
    action   = "deny(403)"
    priority = 3000
    match {
      expr {
        expression = "int(request.headers['content-length']) > 10485760"
      }
    }
    description = "Block requests with body > 10 MB"
  }

  # ─── Default rule: Allow all other traffic ─────────────────────────────
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default: allow all traffic"
  }
}
