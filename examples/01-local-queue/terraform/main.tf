terraform {
  required_version = ">= 1.6"
  required_providers {
    barndoor = {
      source  = "barndoor-ai/barndoor"
      version = "~> 0.10"
    }
  }
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

module "barndoor" {
  source = "../../../terraform/modules/barndoor-sre"

  agent_name    = var.agent_name
  enable_docker = true
}

output "barndoor_server_slugs" {
  value = module.barndoor.server_slugs
}
