terraform {
  required_version = ">= 1.6"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.50"
    }
  }
}

locals {
  dashboard_uid = "flux-capacitor"

  common_labels = {
    service     = "flux-capacitor"
    container   = var.container_name
    environment = var.environment
    namespace   = var.namespace
  }

  # Each rule is an instant PromQL query (refId A) and a threshold
  # expression on it (refId C). The panel ids match dashboard.json so Grafana
  # links each alert to its panel.
  rules = {
    FluxCapacitorOverload = {
      expr      = "max(flux_capacitor_gigawatts)"
      op        = "gt"
      threshold = 1.21
      for       = "30s"
      severity  = "warning"
      panel_id  = 1
      no_data   = "OK"
      summary   = "Flux capacitor output is above the 1.21 GW safety limit"
    }
    HighErrorRate = {
      expr      = "sum(rate(http_requests_total{status=~\"5..\"}[1m])) / sum(rate(http_requests_total[1m]))"
      op        = "gt"
      threshold = 0.05
      for       = "30s"
      severity  = "critical"
      panel_id  = 2
      no_data   = "OK"
      summary   = "More than 5% of requests are failing with HTTP 5xx"
    }
    HighLatency = {
      expr      = "sum(rate(http_request_duration_seconds_sum[1m])) / sum(rate(http_request_duration_seconds_count[1m]))"
      op        = "gt"
      threshold = 0.5
      for       = "30s"
      severity  = "warning"
      panel_id  = 3
      no_data   = "OK"
      summary   = "Average request latency is above 500ms"
    }
    FluxCapacitorDown = {
      expr      = "max(up{job=\"flux-capacitor\"})"
      op        = "lt"
      threshold = 1
      for       = "20s"
      severity  = "critical"
      panel_id  = 4
      no_data   = "Alerting"
      summary   = "Prometheus cannot scrape the flux capacitor"
    }
  }
}

resource "grafana_data_source" "prometheus" {
  type       = "prometheus"
  name       = "Prometheus"
  uid        = "prometheus"
  url        = var.prometheus_url
  is_default = true
}

resource "grafana_folder" "sre" {
  title = "SRE Example"
}

resource "grafana_dashboard" "flux" {
  folder      = grafana_folder.sre.uid
  config_json = templatefile("${path.module}/dashboard.json", { datasource_uid = grafana_data_source.prometheus.uid })
  overwrite   = true
}

resource "grafana_rule_group" "flux" {
  name             = "flux-capacitor"
  folder_uid       = grafana_folder.sre.uid
  interval_seconds = 10

  dynamic "rule" {
    for_each = local.rules
    content {
      name           = rule.key
      condition      = "C"
      for            = rule.value.for
      no_data_state  = rule.value.no_data
      exec_err_state = "Error"

      labels = merge(local.common_labels, { severity = rule.value.severity })
      annotations = {
        summary          = rule.value.summary
        description      = "${rule.value.expr} ${rule.value.op == "gt" ? ">" : "<"} ${rule.value.threshold} for ${rule.value.for}"
        threshold        = tostring(rule.value.threshold)
        dashboard_uid    = local.dashboard_uid
        __dashboardUid__ = local.dashboard_uid
        __panelId__      = tostring(rule.value.panel_id)
      }

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.prometheus.uid
        relative_time_range {
          from = 300
          to   = 0
        }
        model = jsonencode({
          refId         = "A"
          expr          = rule.value.expr
          instant       = true
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "A"
          conditions = [{
            evaluator = { type = rule.value.op, params = [rule.value.threshold] }
          }]
        })
      }
    }
  }

  depends_on = [grafana_dashboard.flux]
}

# Alerts leave Grafana through one webhook: the bridge, which forwards them
# onto the agent's alert/firing queue.
resource "grafana_contact_point" "sre_bridge" {
  name = "sre-agent-bridge"

  webhook {
    url                       = var.bridge_url
    http_method               = "POST"
    authorization_scheme      = "Bearer"
    authorization_credentials = var.bridge_token
    disable_resolve_message   = false
  }
}

resource "grafana_notification_policy" "root" {
  contact_point   = grafana_contact_point.sre_bridge.name
  group_by        = ["alertname"]
  group_wait      = "10s"
  group_interval  = "1m"
  repeat_interval = "4h"
}

# The identity Barndoor's Grafana connector uses on the agent's behalf.
# Editor, not Viewer, because Grafana only lets editors create annotations;
# the Barndoor policy is what narrows the agent to read tools plus
# postAnnotation.
resource "grafana_service_account" "sre_agent" {
  name = "sre-agent"
  role = "Editor"
}

resource "grafana_service_account_token" "sre_agent" {
  name               = "barndoor-connector"
  service_account_id = grafana_service_account.sre_agent.id
}
