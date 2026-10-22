# One-time LLM gateway setup for the trial org, shared by every example:
# Anthropic credential -> provider -> model -> "sre-agent" route, plus a
# daily token budget on the SRE agent. Run with ../../scripts/setup-llm-gateway.sh.
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

data "barndoor_agent" "sre" {
  name = var.agent_name
}

module "llm" {
  source = "../modules/barndoor-llm"

  agent_id          = data.barndoor_agent.sre.id
  anthropic_api_key = var.anthropic_api_key
  upstream_model    = var.upstream_model
}

output "llm_model" {
  description = "Set LLM_MODEL to this in .env."
  value       = module.llm.model_alias
}

output "provider_health" {
  value = module.llm.provider_health
}

variable "barndoor_base_url" {
  type    = string
  default = "https://platform.barndoor.ai"
}

variable "barndoor_token_url" {
  type = string
}

variable "barndoor_client_id" {
  type = string
}

variable "barndoor_client_secret" {
  type      = string
  sensitive = true
}

variable "barndoor_organization_id" {
  type = string
}

variable "agent_name" {
  type    = string
  default = "SRE Example Agent"
}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
}

variable "upstream_model" {
  type    = string
  default = "claude-sonnet-5-5"
}

# Set by the shared scripts for every root; unused here.
variable "bridge_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "grafana_admin_password" {
  type      = string
  default   = ""
  sensitive = true
}
