variable "agent_id" {
  description = "Registration id of the SRE agent (the daily budget is scoped to it)."
  type        = string
}

variable "anthropic_api_key" {
  description = "Anthropic API key the gateway uses upstream."
  type        = string
  sensitive   = true
}

variable "provider_name" {
  description = "Display name of the gateway provider. Callers can also address a model as \"<provider_name>/<model>\"."
  type        = string
  default     = "Anthropic SRE Example"
}

variable "upstream_model" {
  description = "Anthropic model id the route serves."
  type        = string
  default     = "claude-sonnet-5-5"
}

variable "model_alias" {
  description = "Route name the agent calls (LLM_MODEL in .env)."
  type        = string
  default     = "sre-agent"
}

variable "daily_token_limit" {
  description = "Daily token budget for the SRE agent; 0 disables the budget."
  type        = number
  default     = 2000000
}
