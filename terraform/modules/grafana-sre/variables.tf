variable "prometheus_url" {
  description = "Prometheus URL as Grafana's server sees it."
  type        = string
  default     = "http://prometheus:9090"
}

variable "bridge_url" {
  description = "Where Grafana sends alert notifications (the bridge's /grafana endpoint, as Grafana's server sees it)."
  type        = string
  default     = "http://bridge:9095/grafana"
}

variable "bridge_token" {
  description = "Shared bearer token the bridge requires (scripts/lib.sh generates it in .state/bridge-token)."
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "environment label stamped on every alert."
  type        = string
  default     = "local"
}

variable "namespace" {
  description = "namespace label stamped on every alert."
  type        = string
  default     = "docker-compose"
}

variable "container_name" {
  description = "container label stamped on every alert (the app's container name)."
  type        = string
  default     = "sre-example-app"
}
