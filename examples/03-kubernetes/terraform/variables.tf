# Every value is supplied by ../apply.sh from .env and .state/ as TF_VAR_*.

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

variable "grafana_instance" {
  description = "The tunnel hostname in front of the sandbox Grafana, e.g. abc-def.trycloudflare.com."
  type        = string
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "bridge_token" {
  type      = string
  sensitive = true
}
