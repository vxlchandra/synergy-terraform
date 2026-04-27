# =============================================================================
# networking.tf — VPC, Subnets, Cloud NAT, Private Service Connection
# =============================================================================

# Custom VPC for backend services
resource "google_compute_network" "aeromontek_vpc" {
  name                    = var.vpc_name
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Subnet for Spring Boot API
resource "google_compute_subnetwork" "springboot_subnet" {
  name          = "${var.vpc_name}-springboot"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.aeromontek_vpc.id
  ip_cidr_range = var.springboot_subnet_cidr

  private_ip_google_access = true
}

# Subnet for Classifier API
resource "google_compute_subnetwork" "classifier_subnet" {
  name          = "${var.vpc_name}-classifier"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.aeromontek_vpc.id
  ip_cidr_range = var.classifier_subnet_cidr

  private_ip_google_access = true
}

# Private Service Connection subnet for Cloud SQL
resource "google_compute_subnetwork" "private_svc_subnet" {
  name          = "${var.vpc_name}-private-svc"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.aeromontek_vpc.id
  ip_cidr_range = var.private_svc_subnet_cidr

  private_ip_google_access = true
}

# Reserved IP range for private service connection (Cloud SQL)
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "${var.vpc_name}-private-ip"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.aeromontek_vpc.id
  address       = "10.100.0.0"
}

# Private service connection for Cloud SQL
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.aeromontek_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# Cloud Router for Cloud NAT
resource "google_compute_router" "nat_router" {
  name    = "${var.vpc_name}-nat-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.aeromontek_vpc.id

  bgp {
    asn = 64514
  }
}

# Cloud NAT for outbound internet access (OpenAI, HuggingFace, Firebase, etc.)
resource "google_compute_router_nat" "cloud_nat" {
  name                                = "${var.vpc_name}-nat"
  router                              = google_compute_router.nat_router.name
  project                             = var.project_id
  region                              = google_compute_router.nat_router.region
  nat_ip_allocate_option              = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat  = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  enable_endpoint_independent_mapping = false

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall: allow internal VPC traffic
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.vpc_name}-allow-internal"
  project = var.project_id
  network = google_compute_network.aeromontek_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = [
    var.springboot_subnet_cidr,
    var.classifier_subnet_cidr,
    var.private_svc_subnet_cidr
  ]
}

# Firewall: allow Google Cloud health check probes
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.vpc_name}-allow-health-checks"
  project = var.project_id
  network = google_compute_network.aeromontek_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["8080", "8081"]
  }

  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22"
  ]
}

# Firewall: allow IAP (Identity-Aware Proxy) for debugging
resource "google_compute_firewall" "allow_iap" {
  name    = "${var.vpc_name}-allow-iap"
  project = var.project_id
  network = google_compute_network.aeromontek_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }

  source_ranges = ["35.235.240.0/20"]
}
