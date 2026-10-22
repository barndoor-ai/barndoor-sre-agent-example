output "dashboard_uid" {
  value = grafana_dashboard.flux.uid
}

output "dashboard_url" {
  value = grafana_dashboard.flux.url
}

output "agent_service_account_token" {
  description = "Paste into Barndoor: Agents -> <agent> -> Connections -> sre-grafana."
  value       = grafana_service_account_token.sre_agent.key
  sensitive   = true
}
