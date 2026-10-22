output "model_alias" {
  description = "Put this in .env as LLM_MODEL."
  value       = barndoor_llm_model_mapping.route.model_alias
}

output "provider_health" {
  description = "The gateway's last connectivity probe of the upstream provider."
  value       = barndoor_llm_provider.anthropic.health_status
}
