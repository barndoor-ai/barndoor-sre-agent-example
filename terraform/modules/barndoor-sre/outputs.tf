output "agent_id" {
  description = "Registration id of the SRE agent."
  value       = data.barndoor_agent.sre.id
}

output "server_slugs" {
  description = "Slugs the agent uses in execute_tool calls."
  value = compact([
    one(barndoor_mcp_server.docker[*].slug),
    one(barndoor_mcp_server.grafana[*].slug),
    one(barndoor_mcp_server.kubernetes[*].slug),
  ])
}

output "grafana_server_id" {
  description = "Id of the Grafana MCP server; connect it for the agent under Agents -> <agent> -> Connections."
  value       = one(barndoor_mcp_server.grafana[*].id)
}
