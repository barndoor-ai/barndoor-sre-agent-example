variable "agent_name" {
  description = "Display name of the SRE agent created in the Barndoor console (Agents -> Add agent)."
  type        = string
  default     = "SRE Example Agent"
}

variable "server_prefix" {
  description = "Prefix for the MCP server instances. The agent's prompts expect the default, which yields the slugs sre-docker, sre-grafana and sre-kubernetes."
  type        = string
  default     = "sre"
}

variable "enable_docker" {
  description = "Install the embedded Docker server (example 01) with a read-only policy for the agent."
  type        = bool
  default     = false
}

variable "enable_kubernetes" {
  description = "Install the embedded Kubernetes server (example 03) with a read-only policy for the agent."
  type        = bool
  default     = false
}

variable "grafana_instance" {
  description = "Public hostname of the Grafana the connector should call, without https:// (e.g. abc-def.trycloudflare.com). Empty disables Grafana."
  type        = string
  default     = ""

  validation {
    condition     = !can(regex("^https?://", var.grafana_instance)) && !endswith(var.grafana_instance, "/")
    error_message = "grafana_instance is a bare hostname: no scheme and no trailing slash."
  }
}
