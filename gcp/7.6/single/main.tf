terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-a"
}

# --- Variables ---
#variable "project" {
#  description = "Your GCP Project ID."
#  type        = string
#}

variable "fortigate_password" {
  description = "A secure password for the FortiGate admin user."
  type        = string
  sensitive   = true
}

variable "linux_password" {
  description = "A secure password for the tfadmin user on the Linux VMs."
  type        = string
  sensitive   = true
}

# --- Virtual Networks ---
# VPC for the FortiGate's external interface
resource "google_compute_network" "external_vpc" {
  name                    = "external-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# VPC for all internal resources
resource "google_compute_network" "seahk_pl_interview_vnet" {
  name                    = "seahk-pl-interview-vnet"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# --- Subnets ---
resource "google_compute_subnetwork" "out_subnet" {
  name          = "seahk-pl-interview-vnet-out"
  region        = "us-central1"
  network       = google_compute_network.external_vpc.id # Attached to external_vpc
  ip_cidr_range = "172.37.0.0/24"
}

resource "google_compute_subnetwork" "in_subnet" {
  name          = "seahk-pl-interview-vnet-in"
  region        = "us-central1"
  network       = google_compute_network.seahk_pl_interview_vnet.id # Attached to internal vnet
  ip_cidr_range = "172.37.1.0/24"
}

resource "google_compute_subnetwork" "web_subnet" {
  name          = "seahk-pl-interview-vnet-web"
  region        = "us-central1"
  network       = google_compute_network.seahk_pl_interview_vnet.id # Attached to internal vnet
  ip_cidr_range = "172.37.2.0/24"
}

resource "google_compute_subnetwork" "app_subnet" {
  name          = "seahk-pl-interview-vnet-app"
  region        = "us-central1"
  network       = google_compute_network.seahk_pl_interview_vnet.id # Attached to internal vnet
  ip_cidr_range = "172.37.3.0/24"
}

# --- GCP Firewall Rule to allow traffic TO the FortiGate ---
resource "google_compute_firewall" "allow_inbound_to_fgt" {
  name    = "allow-inbound-to-fgt"
  network = google_compute_network.external_vpc.id # Rule applies to the external_vpc
  allow {
    protocol = "tcp"
    ports    = ["443", "1022", "1023"]
  }
  allow { protocol = "icmp" }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["fortigate"]
}

# --- Provision FortiGate (PAYG) ---
resource "google_compute_instance" "fortigate_vm" {
  name           = "fortigate-vm"
  machine_type   = "n1-standard-1"
  tags           = ["fortigate"]
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = "projects/fortigcp-project-001/global/images/fortinet-fgtondemand-763-20250423-001-w-license"
      size  = 30
    }
  }

  # NIC 0 attached to the external VPC
  network_interface {
    subnetwork = google_compute_subnetwork.out_subnet.id
    network_ip = "172.37.0.4"
    access_config {} # Binds the Public IP
  }

  # NIC 1 attached to the internal VPC
  network_interface {
    subnetwork = google_compute_subnetwork.in_subnet.id
    network_ip = "172.37.1.4"
  }

  metadata = {
    user-data = templatefile("${path.module}/fortigate_config.txt", { fgt_password = var.fortigate_password })
  }

  service_account {
    scopes = ["userinfo-email", "compute-ro", "storage-ro"]
  }
}

# --- Provision Linux Web Server ---
resource "google_compute_instance" "web_server" {
  name         = "linux-web-server"
  machine_type = "e2-small"
  tags         = ["web"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.web_subnet.id
    network_ip = "172.37.2.10"
  }

  metadata = {
    startup-script = <<-EOF
      #!/bin/bash
      # Install necessary packages
      apt-get update
      apt-get install -y docker.io openssh-server

      # Start and enable Docker
      systemctl start docker
      systemctl enable docker
      docker run --name web-container -d -p 80:80 nginx

      # Create user and set password
      useradd -m -s /bin/bash tfadmin
      echo "tfadmin:${var.linux_password}" | chpasswd
      usermod -aG docker tfadmin

      # Configure SSH to allow password authentication
      # Use sed to replace the line directly for reliability
      sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

      # Restart SSH service to apply changes
      systemctl restart sshd
    EOF
  }
}

# --- Requirement 3.7 & Docker: Provision Linux App Server ---
resource "google_compute_instance" "app_server" {
  name         = "linux-app-server"
  machine_type = "e2-small"
  tags         = ["app"]

  boot_disk {
    initialize_params {
      # Using a standard Debian 12 image
      image = "projects/debian-cloud/global/images/family/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.app_subnet.id
    network_ip = "172.37.3.10"
  }

  metadata = {
    startup-script = <<-EOF
      #!/bin/bash
      # Install necessary packages
      apt-get update
      apt-get install -y docker.io openssh-server

      # Start and enable Docker
      systemctl start docker
      systemctl enable docker
      docker run --name app-container -d -p 8080:80 httpd

      # Create user and set password
      useradd -m -s /bin/bash tfadmin
      echo "tfadmin:${var.linux_password}" | chpasswd
      usermod -aG docker tfadmin

      # Configure SSH to allow password authentication
      # Use sed to replace the line directly for reliability
      sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

      # Restart SSH service to apply changes
      systemctl restart sshd
    EOF
  }
}

# --- GCP Firewall Rule for Internal Communication ---
resource "google_compute_firewall" "allow_internal_traffic" {
  name    = "allow-internal-all"
  network = google_compute_network.seahk_pl_interview_vnet.id

  # Allow all protocols on all ports
  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  # Apply this rule to traffic coming from any internal IP in the VPC
  source_ranges = ["172.37.0.0/16"]

  # This rule applies TO VMs with these tags
  target_tags = ["fortigate", "web", "app"]
}

# --- Create Routing in the internal VPC ---
resource "google_compute_route" "web_to_fgt_route" {
  name        = "route-web-to-fgt"
  dest_range  = "0.0.0.0/0"
  network     = google_compute_network.seahk_pl_interview_vnet.id
  next_hop_ip = google_compute_instance.fortigate_vm.network_interface[1].network_ip
  priority    = 100
  tags        = ["web"]
}

resource "google_compute_route" "app_to_fgt_route" {
  name        = "route-app-to-fgt"
  dest_range  = "0.0.0.0/0"
  network     = google_compute_network.seahk_pl_interview_vnet.id
  next_hop_ip = google_compute_instance.fortigate_vm.network_interface[1].network_ip
  priority    = 100
  tags        = ["app"]
}