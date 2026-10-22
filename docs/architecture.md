# Architecture

## Components

| Component | Path | Role |
|---|---|---|
| Sample app | [app/](../app/main.py) | FastAPI "flux capacitor" service. Exports `flux_capacitor_gigawatts`, `http_requests_total`, `http_request_duration_seconds`; `/chaos/*` endpoints inject faults and log that they did. |
| Alerter | [alerter/](../alerter/alerter.py) | Example 01 only. Scrapes `/metrics`, evaluates [rules.json](../alerter/rules.json) with pending/`for` semantics, posts newly firing alerts. Standard library only. |
| Grafana + Prometheus | [terraform/modules/grafana-sre](../terraform/modules/grafana-sre/main.tf) | Examples 02 and 03. Alert rules, a webhook contact point, a dashboard, and the service account Barndoor's Grafana connector uses. |
| Bridge | [bridge/](../bridge/bridge.py) | Examples 02 and 03. Receives Grafana's webhook, checks its bearer token, flattens each firing alert, skips query-error firings and duplicates, posts to the agent. |
| bobi event server | started by bobi | Durable pub/sub. Alerts arrive on topic `alert/firing` through the token-authenticated ingest webhook. |
| SRE agent | [agent/](../agent/) | A bobi team: `director` and `sre` roles running the `triage` workflow on Claude Code. |
| Barndoor MCP gateway | `barndoor --stdio` | The agent's only tool surface. Authenticates as the agent (M2M), enforces policy, audits every call. |
| Barndoor LLM gateway | `https://app.barndoor.ai/api/llm-gateway` | The agent's only model endpoint. Routes `sre-agent`, attributes usage to the agent, enforces its budget. |

## End to end, example 02

```
1. scripts/break-app.sh overload
2. app: flux_capacitor_gigawatts climbs to ~2.4; logs "CHAOS: overload fault enabled ..."
3. Prometheus scrapes it every 5s
4. Grafana rule FluxCapacitorOverload: max(flux_capacitor_gigawatts) > 1.21 for 30s -> firing
5. Notification policy -> contact point "sre-agent-bridge" -> POST http://bridge:9095/grafana (Bearer)
6. bridge: flatten -> POST http://host.docker.internal:8080/webhooks/ingest/alert/firing (Bearer ingest token)
7. bobi event server: event type alert/firing, fields = the payload's top-level primitives
8. bobi reactor: auto_dispatch rule matches -> launch workflow "triage" with ${{input.*}} = fields
9. triage:  ack (director) -> investigate (sre) -> post_findings (director)
            -> [root cause confident?] -> deep_dive (sre) -> post_deep_dive (director)
            -> synthesize (sre) -> conclude (director)
10. sre steps call barndoor --stdio:  execute_tool("sre-grafana", "queryMetricsWithExpressions", ...)
11. director writes incidents/<incident_id>.md via sre-note, and posts the verdict
    with execute_tool("sre-grafana", "postAnnotation", ...) -> appears on the dashboard
```

Examples 01 and 03 differ only at the edges: in 01 the alerter replaces steps
3 to 6 and the agent reads `sre-docker` instead of Grafana; in 03 every box
runs in a kind cluster and the agent adds `sre-kubernetes`.

## The alert contract

bobi copies only the **top-level string, number and boolean fields** of an
ingested JSON body into the event's `fields`, and the triage workflow's
`${{input.*}}` variables come only from there. Nested objects never reach the
workflow, and a referenced field that is absent renders as an empty string.
So every alert source in this repo (the alerter, the bridge, and the
fixtures) sends the same flat object:

| Field | Example | Notes |
|---|---|---|
| `incident_id` | `FluxCapacitorOverload-05a7a86fbb2b-1792524390` | Unique per firing; names the incident record file |
| `title`, `alertname` | `FluxCapacitorOverload` | |
| `severity` | `warning` / `critical` / `info` | |
| `state` | `firing` | Resolved alerts are not forwarded |
| `summary`, `description` | human text; the firing condition | |
| `value`, `threshold` | `2.429`, `1.21` | The measured value and the rule's threshold |
| `service`, `container` | `flux-capacitor`, `sre-example-app` | Where to look |
| `environment`, `namespace` | `local` / `docker-compose`, `kind` / `sre-demo` | |
| `started_at` | ISO 8601 | |
| `permalink` | Grafana panel URL, or the app's `/chaos` | |
| `dashboard_uid` | `flux-capacitor` or empty | Where the director annotates |
| `kube_context` | `sre-sandbox` or empty | Example 03 |
| `source` | `alerter` / `grafana` / `fixture` | |

Any system that can POST this JSON with the ingest token can page the agent:

```bash
curl -X POST "$BOBI_INGEST_URL" \
  -H "Authorization: Bearer $BOBI_INGEST_TOKEN" \
  -H 'Content-Type: application/json' \
  --data @fixtures/flux-capacitor-overload.json
```

## The agent package

```
agent/
  agent.yaml        what bobi runs: brain, subscription, auto_dispatch, MCP server
  agent.md          team-wide directives every session sees
  roles/director    the human-facing voice: ack, notes, verdict, escalation call
  roles/sre         the investigator: tool catalog, strategy, read-only rules
  workflows/triage.yaml
  tools/barndoor.md how to use Barndoor's meta-tools
  bin/sre-note      the incident-record CLI
```

Things in `agent.yaml` that are easy to get wrong, all learned from the
production agent:

- **The `auto_dispatch` task is context, not an instruction.** bobi runs the
  task text as a standalone prompt before step 1. An imperative "triage this
  alert" makes the model do the whole job there, outside the workflow.
- **`role: ""`** lets each workflow step pick its own role (`director` or
  `sre`).
- **`brain.base_url` has no `/v1`**; Claude Code appends `/v1/messages`.
- **Credentials ride the MCP server's `env` block**, never its `args`, so
  they do not show up in process listings.
- **The MCP command is an absolute path**, because bobi's MCP preflight runs
  without your shell's `PATH`.
- **`prune: monitors: [sleep-cycle]`** removes bobi's default 6-hourly memory
  distillation, which would spend tokens on a timer.

`scripts/agent-up.sh` adds two runtime details: it seeds Claude Code's
workspace-trust flag for the agent's run directory (headless Claude Code
otherwise drops its tool permissions in an untrusted directory, so every turn
runs without tools), and it sets `BOBI_COMMUNICATION_STYLE=off` so bobi does
not write an instructions block into `~/AGENTS.md`.

## Governance, in one place

| Control | Where | Effect here |
|---|---|---|
| Agent identity | Console: AI Agents | Every tool and model call is attributed to "SRE Example Agent" |
| MCP policies | `terraform/modules/barndoor-sre` | Read-tool allowlists per server; anything else is denied |
| Write confirmations | Agent setting or per-tool policy | Decides whether the one write (an annotation) needs a human |
| Grafana service account | `terraform/modules/grafana-sre` | The connector's identity in Grafana; scoped to this agent's connection |
| LLM route | `terraform/modules/barndoor-llm` | The agent asks for `sre-agent`; the org decides which model serves it |
| Token budget | `terraform/modules/barndoor-llm` | Daily cap on the agent's model usage; blocks when exhausted |
| Kubernetes RBAC | `examples/03-kubernetes/k8s/sre-agent.yaml` | Read-only ClusterRole: even a policy mistake cannot become a cluster write |
| Audit history | Console | Every allowed and denied call |
