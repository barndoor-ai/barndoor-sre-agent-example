terraform {
  required_version = ">= 1.6"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.50"
    }
    barndoor = {
      source  = "barndoor-ai/barndoor"
      version = "~> 0.10"
    }
  }
}

# The sandbox Grafana from docker-compose.yaml.
provider "grafana" {
  url  = "http://localhost:3000"
  auth = "admin:${var.grafana_admin_password}"
}

# Configured explicitly so the provider never falls back to the
# BARNDOOR_CLIENT_ID/SECRET environment variables, which in this repo hold
# the agent's credentials rather than an admin credential.
provider "barndoor" {
  base_url        = var.barndoor_base_url
  token_url       = var.barndoor_token_url
  client_id       = var.barndoor_client_id
  client_secret   = var.barndoor_client_secret
  organization_id = var.barndoor_organization_id
}

module "grafana" {
  source = "../../../terraform/modules/grafana-sre"

  prometheus_url = "http://prometheus:9090"
  bridge_url     = "http://bridge:9095/grafana"
  bridge_token   = var.bridge_token
  environment    = "local"
  namespace      = "docker-compose"
  container_name = "sre-example-app"
}

module "barndoor" {
  source = "../../../terraform/modules/barndoor-sre"

  agent_name       = var.agent_name
  grafana_instance = var.grafana_instance
}
