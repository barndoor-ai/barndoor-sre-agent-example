terraform {
  required_version = ">= 1.6"
  required_providers {
    barndoor = {
      source  = "barndoor-ai/barndoor"
      version = "~> 0.10"
    }
  }
}

# The upstream credential. Write-only: Barndoor stores it in its secret
# store and never returns it.
resource "barndoor_llm_connection" "anthropic" {
  name           = "${var.provider_name} key"
  model_provider = "anthropic"
  base_url       = "https://api.anthropic.com"
  api_key        = var.anthropic_api_key
}

resource "barndoor_llm_provider" "anthropic" {
  name           = var.provider_name
  model_provider = "anthropic"
  connection_id  = barndoor_llm_connection.anthropic.id
}

# Enable the upstream model on the provider (addressable as
# "<provider name>/<upstream_model>")...
resource "barndoor_llm_model_mapping" "model" {
  provider_id    = barndoor_llm_provider.anthropic.id
  model_alias    = var.upstream_model
  upstream_model = var.upstream_model
}

# ...and give the agent a stable route name to call. Swapping the model
# behind the route later needs no agent change.
resource "barndoor_llm_model_mapping" "route" {
  provider_id    = barndoor_llm_provider.anthropic.id
  model_alias    = var.model_alias
  upstream_model = var.upstream_model
  bare_alias     = true

  depends_on = [barndoor_llm_model_mapping.model]
}

# Governance: cap what the SRE agent can spend per day. Exhaustion blocks
# further model calls until the window rolls over.
resource "barndoor_llm_token_budget" "agent_daily" {
  count             = var.daily_token_limit > 0 ? 1 : 0
  name              = "SRE example agent daily tokens"
  scope_type        = "agent"
  scope_id          = var.agent_id
  period            = "daily"
  token_limit       = var.daily_token_limit
  alert_thresholds  = [50, 80]
  action_on_exhaust = "block"
  traffic_type      = "llm"
}
