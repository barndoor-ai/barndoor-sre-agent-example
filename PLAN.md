# Barndoor SRE Agent Example — Implementation Plan

> **Status: implemented (2026-10-20).** The repository now follows this plan;
> [README.md](README.md) and [docs/](docs/) are the current documentation.
> Deviations, each made after checking the real behavior:
>
> - **Example 01's alerter is a standalone script, not a bobi `command:`
>   monitor.** Monitor findings are published with a bare event type
>   (`firing`, not `alert/firing`) and no `fields`, so `auto_dispatch` would
>   never match them and `${{input.*}}` would be empty. Only the ingest
>   webhook populates fields, so every alert source posts there.
> - **Grafana reaches Barndoor through a Cloudflare quick tunnel.** The Grafana
>   connector runs in Barndoor's cloud and cannot reach `localhost`; the
>   tenant local-MCP path needs signed binaries hosted on HTTPS.
> - **The Grafana connection is made on the agent in the console.** Terraform's
>   `barndoor_connection` is organization-wide, and agent calls through the
>   CLI resolve agent-owned connections.
> - **The agent's registration stays console-managed** (Terraform reads it
>   with `data.barndoor_agent`), so `terraform destroy` cannot unregister it.
> - **The LLM gateway gets its own Terraform root** (`terraform/llm-gateway`)
>   because trials start with no provider: connection, provider, model, an
>   `sre-agent` route, and a daily token budget on the agent.
> - **The bridge and alerter use only the Python standard library**, so they
>   run from a stock `python` image with no build.
>
> The original plan follows.

---

## Context

Barndoor's production SRE agent (`bdai-platform/services/agents/sre`) is a
[bobi](https://github.com/moda-labs/bobi-agent) agent team: a declarative package
(`agent.yaml`, role prompts, a `triage` workflow state machine) whose "brain" is the
Claude Code CLI and whose only tool surface is the `barndoor --stdio` MCP aggregator,
authenticated with machine-to-machine (M2M) credentials. In production, alerts flow:

```
Grafana alert rule → Grafana OnCall → outgoing webhook → Cloudflare Worker/Queue
  → queue-bridge sidecar → bobi event server (alert/firing) → auto_dispatch → triage workflow
  → director/sre roles investigate via barndoor MCP → OnCall notes / Jira / Slack
```

This repository packages that architecture as a public, reproducible example: a sample
application that raises alerts, a simplified SRE agent, and instructions for wiring it
all to a Barndoor trial account. It is built as a **progression of examples**, each one
adding a production-realistic layer:

| Example | Alert source | Infra | What it teaches |
|---|---|---|---|
| `examples/01-local-queue` | bobi event bus directly (ingest webhook / `events publish`) | docker compose (app only) | Agent anatomy, triage workflow, Barndoor MCP basics |
| `examples/02-grafana` | Real Grafana alerting → webhook bridge → bobi ingest | docker compose (app + Prometheus + Grafana) | Real alert pipeline, Terraform for Grafana **and** Barndoor trial settings |
| `examples/03-kubernetes` | Grafana in-cluster, agent as a Deployment | kind/k3d + Tilt | Production-shaped deployment (mirrors `barndoor-infra/gitops/manifests/infra/sre-agent-bobi/`) |

Key simplifications vs. production (deliberate, documented in each README):
no Grafana OnCall, no Cloudflare Worker/Queue (a small webhook bridge replaces both),
no ExternalSecrets/Workload Identity (plain env files / k8s Secrets), no Jira/Slack
steps in the default workflow (optional extension), no drain/reconcile run-ledger
hardening.

## Repository layout

```
barndoor-sre-agent-example/
├── README.md                     # architecture overview, progression table, quickstart pointers
├── PLAN.md                       # this file (removed or moved to docs/ when the repo is done)
├── app/                          # shared sample application
│   ├── main.py                   # FastAPI "flux-capacitor" service
│   ├── Dockerfile
│   └── README.md
├── agent/                        # shared bobi agent package (installed by every example)
│   ├── agent.yaml
│   ├── agent.md
│   ├── roles/
│   │   ├── director/ROLE.md
│   │   └── sre/ROLE.md
│   ├── workflows/
│   │   └── triage.yaml
│   ├── tools/barndoor.md
│   └── fixtures/                 # synthetic alert payloads (flat, incident_id keyed)
│       ├── high-error-rate.json
│       ├── crashloop.json
│       └── flux-capacitor-overload.json
├── examples/
│   ├── 01-local-queue/
│   │   ├── README.md
│   │   ├── docker-compose.yaml   # sample app only
│   │   ├── .env.example
│   │   └── scripts/
│   │       ├── up.sh             # start app + install agent + start bobi
│   │       ├── fire-alert.sh     # curl POST /webhooks/ingest/alert/firing
│   │       └── break-app.sh      # trips the app's fault injection, monitor raises alert
│   ├── 02-grafana/
│   │   ├── README.md
│   │   ├── docker-compose.yaml   # app + prometheus + grafana + webhook bridge
│   │   ├── bridge/               # ~100-line FastAPI: Grafana webhook → flatten → bobi ingest
│   │   ├── grafana/provisioning/ # datasource (fallback for non-terraform users)
│   │   └── terraform/
│   │       ├── grafana/          # alert rules, contact point, notification policy
│   │       └── barndoor/         # barndoor_agent, barndoor_mcp_server (grafana), barndoor_policy
│   └── 03-kubernetes/
│       ├── README.md
│       ├── Tiltfile
│       ├── k8s/                  # app, prometheus, grafana, bridge, sre-agent manifests
│       │   └── sre-agent/        # deployment, configmap, secret.example, pvc (mirrors prod)
│       └── terraform/            # reuses 02's barndoor module + kubernetes MCP policy
└── docs/
    ├── architecture.md           # diagrams: production flow vs. each example's flow
    ├── barndoor-trial-setup.md   # trial signup, agent registration, M2M credentials
    ├── mcp-servers.md            # configuring grafana/kubernetes/docker connectors + policies
    └── production-reference.md   # how the real agent differs (OnCall, CF queue, GitOps)
```

## Shared components

### 1. Sample application (`app/`)

A single-file FastAPI service, the **flux-capacitor service** (nod to the internal
`sre_demo_flux_capacitor` rule):

- `GET /` — serves traffic; `GET /healthz`; `GET /metrics` — Prometheus format via
  `prometheus-client`.
- Metrics: `http_requests_total{status}`, `http_request_duration_seconds`,
  `flux_capacitor_gigawatts` (gauge, normally ~1.0).
- Fault injection endpoints (this is how a user "breaks" the app to raise real alerts):
  - `POST /chaos/overload` — pushes `flux_capacitor_gigawatts` above 1.21
  - `POST /chaos/errors` — makes a % of requests return 500
  - `POST /chaos/latency` — adds response delay
  - `POST /chaos/reset`
- A tiny built-in load generator thread (toggleable) so metrics move without extra tooling.

### 2. Agent package (`agent/`)

A simplified port of `bdai-platform/services/agents/sre`, reusing its proven structure:

- **`agent.yaml`**: `entry_point: director`, `subscribe: [alert/firing]`,
  `auto_dispatch → workflow: triage` (with the "CONTEXT ONLY … reply and STOP" task
  wording — the internal repo learned this the hard way), `brain.kind: claude`,
  `tool_library` with one MCP server: `barndoor --stdio` + `BARNDOOR_CLIENT_ID/SECRET`
  env. The brain goes through the **Barndoor LLM gateway** by default — this is a core
  part of what the trial showcases: `brain.base_url = ${LLM_GATEWAY_URL}`
  (`https://app.barndoor.ai/api/llm-gateway`, **no trailing `/v1`**), a
  provider-prefixed `LLM_MODEL`, and gateway auth via
  `ANTHROPIC_CUSTOM_HEADERS="x-api-key: <gateway key>"` alongside
  `CLAUDE_CODE_OAUTH_TOKEN` (subscription mode), or `ANTHROPIC_AUTH_TOKEN` set to a
  gateway PAT (api-key mode). Direct-to-Anthropic is documented as a fallback variant
  only.
- **`roles/director`**: human-facing voice; posts triage notes (to stdout/bobi transcript
  in ex1; to a Grafana annotation or the bridge's `/notes` log in ex2/3); never remediates.
- **`roles/sre`**: investigator; read-only rules; per-example tool catalog
  (ex1: `docker` + app endpoints; ex2/3: `grafana` connector slug + `kubernetes`).
- **`workflows/triage.yaml`**: trimmed state machine —
  `ack → metrics (sre) → logs/code (sre) → route (confident?) → synthesize → conclude (director)`
  with `handoff` fields (`finding`, `root_cause_confident`, `root_cause`, `escalate`,
  `recommendation`). Keeps the routing/`goto` pattern so it genuinely demonstrates the
  workflow engine, but ~6 steps instead of 20.
- **`tools/barndoor.md`**: meta-tool usage guide (`search_tools`/`describe_tools`/
  `execute_tool`), adapted from the internal one.
- **Fixtures**: flat payloads keyed on `incident_id` (NOT `alert_group_id` — the internal
  fixtures have a known mismatch with `${{input.incident_id}}`), plus `title`, `severity`,
  `service`, `environment`, `namespace`, `permalink`.

## Example 1 — `01-local-queue` (simplest: bobi queues directly)

**Flow:** `fire-alert.sh` (or a bobi `command:` monitor watching the app) → bobi local
event server `POST /webhooks/ingest/alert/firing` → `auto_dispatch` → triage.

Terminology: bobi has no separate queue API — the event server's topics (`alert/firing`)
*are* the queues. Delivery is durable (sequence numbers, 48h replay), consumed over a
WebSocket subscription and dispatched by the reactor.

- `docker compose up` runs only the sample app.
- bobi runs on the host (`pip install bobi`), with `BOBI_EVENT_SERVER` unset so it
  auto-starts its embedded local event server; ingest token minted via
  `bobi agent sre events ingest-token create alert/firing` (or seeded with
  `BOBI_ES_INGEST_TOKENS`).
- Three ways to raise an alert, in increasing realism:
  1. `scripts/fire-alert.sh <fixture>` — curl the ingest webhook (mirrors
     `services/agents/sre/local/fire-test-alert.sh`).
  2. `bobi agent sre events publish alert/firing --json '{...}'` — signed CLI publish.
  3. `scripts/break-app.sh overload` + a bobi **`command:` monitor** that polls
     `app:/metrics`, evaluates thresholds (gigawatts > 1.21, error rate > 5%), and
     publishes `alert/firing` — a self-contained "alerting system" with no Grafana.
- Investigation tools: `barndoor --stdio` with the trial M2M credentials; the agent uses
  the embedded `docker` server (container status + logs) and the audited shell to curl
  the app. Also documents `BRAIN_KIND=stub` / `BOBI_STUB_BRAIN=1` to test the
  event→dispatch→workflow wiring with zero LLM tokens.
- `.env.example`: `BARNDOOR_CLIENT_ID/SECRET`, `LLM_GATEWAY_URL`, `LLM_MODEL`, and the
  gateway credential (`ANTHROPIC_CUSTOM_HEADERS` x-api-key + `CLAUDE_CODE_OAUTH_TOKEN`,
  or `ANTHROPIC_AUTH_TOKEN` gateway PAT).

## Example 2 — `02-grafana` (real alerting + Terraform + Barndoor provider)

**Flow:** app → Prometheus scrape → Grafana unified alerting → **webhook contact point**
→ `bridge` (replaces OnCall + Cloudflare Worker + Queue + queue_bridge sidecar) → bobi
ingest → triage. The agent investigates via the **Grafana MCP connector** through
Barndoor.

- `docker-compose.yaml`: app, prometheus, grafana (OSS), bridge, all on one network.
  The bridge is a small FastAPI service that ports `flatten_alert_payload` from
  `queue_bridge.py`: receives the Grafana/Alertmanager-shaped webhook, lifts
  `commonLabels.{severity,environment,namespace,service_name,alertname}` to top-level
  fields, dedupes by fingerprint, and POSTs to the bobi ingest URL with the token.
- `terraform/grafana/`: `grafana` provider against the local instance — folder, alert
  rules (`FluxCapacitorOverload: flux_capacitor_gigawatts > 1.21`, `HighErrorRate`,
  `CrashLooping`-style), webhook contact point pointing at the bridge, notification
  policy grouped by `alertname`. (Static provisioning files kept as a no-terraform
  fallback.)
- `terraform/barndoor/`: the **Barndoor provider** configures the trial org:
  - `barndoor_agent` — registers the SRE agent (M2M), `llm_gateway_enabled = true`
    (the brain's traffic runs through the gateway) and
    `write_confirmations_required = false` for unattended triage (called out explicitly
    in docs).
  - `barndoor_mcp_server` — a Grafana MCP server seeded with `prepopulated_credentials`
    (service-account token created by the grafana terraform) + `cascaded_fields`.
  - `barndoor_policy` — ALLOW read-only tool actions for the agent on that server.
  - Variables/outputs so example 3 reuses this as a module.
- Agent `sre` role in this example points at the Grafana connector slug
  (`execute_tool(slug="grafana-sandbox", tool="queryMetricsWithExpressions", ...)`).

## Example 3 — `03-kubernetes` (full stack via Tilt)

**Flow:** same as example 2, but everything — including the agent — runs in a local
kind/k3d cluster, deployed and live-reloaded by **Tilt**.

- `Tiltfile`: builds the app image and an agent image
  (`FROM python:3.11-slim` + `pip install bobi` + Claude Code CLI + `barndoor` CLI
  download + `COPY agent/ /opt/bobi/team/` + an entrypoint adapted from
  `services/agents/sre/entrypoint.sh` — keeping workspace-trust seeding and
  `bobi agents install`, dropping login ceremony/drain/reconcile).
- `k8s/`: namespace, app Deployment+Service+ServiceMonitor-or-scrape-config, Prometheus,
  Grafana (provisioned from example 2's config), bridge, and `sre-agent/` manifests
  modeled on `barndoor-infra/gitops/manifests/infra/sre-agent-bobi/` (Deployment with
  `strategy: Recreate`, ConfigMap → `render_runtime_env` pattern, PVC for `/data`,
  plain Secret with an `.example` template instead of ExternalSecret).
- Agent investigates with the **kubernetes** embedded server (in-cluster service
  account kubeconfig, read-only RBAC modeled on `sre-agent-readonly` ClusterRole) plus
  the Grafana connector.
- `terraform/`: reuses `02-grafana/terraform/barndoor` as a module; adds the policy for
  the kubernetes server.

## Documentation

- **`docs/barndoor-trial-setup.md`** — create a trial org at barndoor.ai; register an
  agent to get `BARNDOOR_CLIENT_ID/SECRET` (UI path, and the Terraform path as done in
  example 2); enable the LLM gateway for the agent and obtain the gateway credential
  (key for `ANTHROPIC_CUSTOM_HEADERS` / gateway PAT) and model id; install the
  `barndoor` CLI; verify with a `barndoor --stdio` smoke test and a one-shot gateway
  completion.
- **`docs/mcp-servers.md`** — how connectors work (directory entry → `barndoor_mcp_server`
  instance → connection → policy), configuring Grafana with a service-account token,
  the embedded servers (kubernetes/docker/shell), write-confirmation behavior and why
  the example disables it for the agent, and the meta-tool calling pattern.
- **`docs/architecture.md`** — side-by-side diagrams: production pipeline
  (OnCall/Cloudflare) vs. each example's pipeline, and a mapping table
  ("this example's `bridge/` ≈ production's Cloudflare Worker + queue_bridge.py").
- **`docs/production-reference.md`** — pointers to what production adds: OnCall
  escalation chains, Cloudflare queue durability, Jira/Slack/telemetry steps,
  drain/reconcile, GitOps/Kargo delivery.

## Build order

1. **Scaffold + sample app** — repo layout, `app/` with metrics and chaos endpoints,
   root README skeleton. Verify: `docker compose up`, curl `/metrics`, trip
   `/chaos/overload`, watch the gauge.
2. **Agent package + Example 1** — `agent/`, fixtures, scripts. Verify end-to-end with
   `BRAIN_KIND=stub` first (no tokens), then a real run: fire `flux-capacitor-overload`,
   confirm `auto_dispatch` starts `triage`, steps hand off, director produces the
   four-line conclusion. This is the critical validation gate for everything downstream.
3. **Example 2** — compose stack, bridge, grafana terraform, barndoor terraform. Verify:
   `break-app.sh overload` → Grafana rule fires → bridge log shows flatten+ingest →
   triage run queries Grafana via the connector.
4. **Docs** — trial setup + MCP servers (written alongside 2, since that's where the
   Barndoor wiring becomes real).
5. **Example 3** — Tilt + manifests + agent image. Verify: `tilt up`, same break/triage
   cycle, agent pod uses in-cluster kubernetes tools.

## Open items / assumptions (flag if wrong)

- **bobi version**: pin `bobi==0.58.x` (what production uses). The repo is public on
  GitHub and the package is on PyPI, so trial users can install it.
- **LLM auth default**: the Barndoor LLM gateway (per the trial's purpose). Needs
  confirming exactly how a trial org issues the gateway credential and model id
  (production uses a hand-populated `sre-agent-llm-gateway` secret `{api_key, model}` —
  the trial-facing flow for this must be verified and documented). Direct
  `ANTHROPIC_API_KEY` kept as a documented fallback for users whose trial lacks gateway
  access.
- **No Jira/Slack in the default workflow** — keeps trial prerequisites minimal; an
  optional `ticketing` step with the `atlassian` connector is described in docs as an
  extension.
- **Grafana MCP directory entry**: example 2 assumes a Grafana connector exists in the
  Barndoor directory that accepts a service-account token via `prepopulated_credentials`;
  the exact `mcp_server_directory_id` needs to be confirmed against the trial directory.
