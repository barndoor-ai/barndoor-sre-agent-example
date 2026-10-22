# Every value is supplied by ../apply.sh from .env as TF_VAR_*.

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

# Set by apply.sh for every example; unused here.
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
