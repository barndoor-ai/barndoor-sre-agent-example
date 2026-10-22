output "dashboard_url" {
  value = module.grafana.dashboard_url
}

output "grafana_public_url" {
  value = "https://${var.grafana_instance}"
}

output "barndoor_server_slugs" {
  value = module.barndoor.server_slugs
}

output "grafana_connector_token" {
  description = "terraform output -raw grafana_connector_token, then paste it into Agents -> <agent> -> Connections -> sre-grafana."
  value       = module.grafana.agent_service_account_token
  sensitive   = true
}
