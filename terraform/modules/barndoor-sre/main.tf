terraform {
  required_version = ">= 1.6"
  required_providers {
    barndoor = {
      source  = "barndoor-ai/barndoor"
      version = "~> 0.10"
    }
  }
}

# The agent itself (its OAuth client and one-time secret) is created in the
# Barndoor console; Terraform only reads it here. Managing the registration
# with barndoor_agent would mean `terraform destroy` unregisters the agent and
# invalidates the credentials the example is running with.
data "barndoor_agent" "sre" {
  name = var.agent_name
}

check "agent_uses_llm_gateway" {
  assert {
    condition     = data.barndoor_agent.sre.llm_gateway_enabled
    error_message = "Agent '${var.agent_name}' does not have the LLM Gateway enabled; turn it on under Agents -> ${var.agent_name} -> Edit, or the agent's brain calls will be rejected."
  }
}

check "director_can_annotate_unattended" {
  assert {
    condition     = var.grafana_instance == "" || !data.barndoor_agent.sre.write_confirmations_required
    error_message = "Agent '${var.agent_name}' requires write confirmations, so the director's Grafana annotation (the one write this agent makes) will wait for a human. Turn write confirmations off for the agent if you want unattended annotations; the read-only policies below still bound what it can do."
  }
}

locals {
  docker_read_tools = [
    "list_containers",
    "inspect_container",
    "container_logs",
  ]

  kubernetes_read_tools = [
    "list_contexts",
    "list_namespaces",
    "get_namespace",
    "list_pods",
    "get_pod",
    "get_pod_logs",
    "get_pod_metrics",
    "list_deployments",
    "get_deployment",
    "list_services",
    "get_service",
    "list_events",
    "list_object_events",
    "get_resource",
    "list_resources",
    "describe_resource",
    "rollout_status",
    "rollout_history",
  ]

  grafana_read_tools = [
    "getDataSources",
    "getDataSourceByUID",
    "getDataSourceByName",
    "checkDatasourceHealthWithUID",
    "queryMetricsWithExpressions",
    "getDashboardByUID",
    "getFolders",
    "getAnnotations",
  ]

  # The director's single sanctioned write: publishing its verdict.
  grafana_write_tools = ["postAnnotation"]
}

# --- Docker (embedded: runs inside the agent's own barndoor CLI) ------------

data "barndoor_mcp_server_directory" "docker" {
  count = var.enable_docker ? 1 : 0
  slug  = "docker"
}

resource "barndoor_mcp_server" "docker" {
  count                   = var.enable_docker ? 1 : 0
  name                    = "${var.server_prefix}-docker"
  mcp_server_directory_id = data.barndoor_mcp_server_directory.docker[0].id
}

resource "barndoor_policy" "docker" {
  count           = var.enable_docker ? 1 : 0
  name            = "${var.agent_name} - Docker read-only"
  description     = "The SRE agent may read container state and logs. Every other Docker tool (create, exec, stop, remove, pull, push, ...) is denied because no rule allows it."
  mcp_server_id   = barndoor_mcp_server.docker[0].id
  application_ids = [data.barndoor_agent.sre.id]
  status          = "ACTIVE"
  tags            = ["sre-example"]

  rules = [{
    name    = "read container state and logs"
    effect  = "ALLOW"
    actions = [for tool in local.docker_read_tools : "tools/call:${tool}"]
    roles   = ["*"]
  }]
}

# --- Kubernetes (embedded) --------------------------------------------------

data "barndoor_mcp_server_directory" "kubernetes" {
  count = var.enable_kubernetes ? 1 : 0
  slug  = "kubernetes"
}

resource "barndoor_mcp_server" "kubernetes" {
  count                   = var.enable_kubernetes ? 1 : 0
  name                    = "${var.server_prefix}-kubernetes"
  mcp_server_directory_id = data.barndoor_mcp_server_directory.kubernetes[0].id
}

resource "barndoor_policy" "kubernetes" {
  count           = var.enable_kubernetes ? 1 : 0
  name            = "${var.agent_name} - Kubernetes read-only"
  description     = "The SRE agent may read pods, logs, events and workload state. Writes (delete, exec, scale, restart, apply, patch, ...) are denied because no rule allows them."
  mcp_server_id   = barndoor_mcp_server.kubernetes[0].id
  application_ids = [data.barndoor_agent.sre.id]
  status          = "ACTIVE"
  tags            = ["sre-example"]

  rules = [{
    name    = "read cluster state"
    effect  = "ALLOW"
    actions = [for tool in local.kubernetes_read_tools : "tools/call:${tool}"]
    roles   = ["*"]
  }]
}

# --- Grafana (remote connector: runs in Barndoor's cloud) -------------------

data "barndoor_mcp_server_directory" "grafana" {
  count = var.grafana_instance != "" ? 1 : 0
  slug  = "grafana"
}

resource "barndoor_mcp_server" "grafana" {
  count                   = var.grafana_instance != "" ? 1 : 0
  name                    = "${var.server_prefix}-grafana"
  mcp_server_directory_id = data.barndoor_mcp_server_directory.grafana[0].id

  # The connector calls https://<instance>. It runs in Barndoor's cloud, so
  # the instance must be reachable from the internet (the examples use a
  # Cloudflare quick tunnel in front of the local Grafana).
  meta = jsonencode({
    access_context = {
      instance = var.grafana_instance
    }
  })
}

resource "barndoor_policy" "grafana" {
  count           = var.grafana_instance != "" ? 1 : 0
  name            = "${var.agent_name} - Grafana read + annotate"
  description     = "The SRE agent may query metrics and read dashboards, and the director may post its verdict as an annotation. Everything else (dashboards, datasources, folders, teams) is denied because no rule allows it."
  mcp_server_id   = barndoor_mcp_server.grafana[0].id
  application_ids = [data.barndoor_agent.sre.id]
  status          = "ACTIVE"
  tags            = ["sre-example"]

  rules = [
    {
      name    = "query metrics and read dashboards"
      effect  = "ALLOW"
      actions = [for tool in local.grafana_read_tools : "tools/call:${tool}"]
      roles   = ["*"]
    },
    {
      name    = "publish the triage verdict"
      effect  = "ALLOW"
      actions = [for tool in local.grafana_write_tools : "tools/call:${tool}"]
      roles   = ["*"]
    },
  ]
}
