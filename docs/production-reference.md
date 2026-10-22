# How this example maps to Barndoor's production SRE agent

Barndoor runs this same kind of agent against its own platform. This page
lists what the example keeps, what it replaces, and what it leaves out, so you
can see the path from here to production.

## Kept as is

- **The framework:** a [bobi](https://github.com/moda-labs/bobi-agent) agent
  team with a `director` (the only voice to humans) and an `sre`
  (investigator), driven by a YAML `triage` workflow with handoffs and routing
  steps.
- **Alert ingestion:** alerts arrive on the bobi event server's `alert/firing`
  topic through the token-authenticated ingest webhook, as flat payloads, and
  an `auto_dispatch` rule launches `triage`.
- **Barndoor wiring:** one MCP server, `barndoor --stdio`, authenticated with
  the agent's M2M credentials passed through the MCP `env` block; Claude Code
  pointed at the Barndoor LLM gateway.
- **Prompt discipline:** investigate first, never remediate, cite evidence or
  say it is missing, a fixed four-line verdict with an explicit escalation
  call, and a context-only `auto_dispatch` task.
- **Deployment shape (example 03):** one replica, `Recreate` strategy, a
  persistent volume for state, a read-only ClusterRole, an entrypoint that
  seeds workspace trust and reinstalls the package on every boot.

## Replaced with something simpler

| Production | This example | Why |
|---|---|---|
| Grafana Cloud alert rules → Grafana OnCall integration and escalation chain → OnCall outgoing webhook | Grafana OSS alert rules → webhook contact point | OnCall is not part of a sandbox |
| Cloudflare Worker (bearer check) → Cloudflare Queue → `queue_bridge.py` sidecar (pull, flatten, dedupe, ack) | `bridge/bridge.py` (bearer check, flatten, dedupe, forward) | One hop instead of three; the queue's durability matters less on a laptop |
| Hosted bobi event server (Cloudflare Worker) | bobi's embedded local event server | No deployment needed |
| OnCall resolution notes, acknowledge and resolve | `sre-note` markdown records + a Grafana annotation | Same "single incident record" idea without OnCall |
| Grafana Cloud, Google Managed Prometheus, Cloud Logging | Local Prometheus and Grafana | Sandbox |
| Several GKE clusters, AlloyDB and CNPG databases, ArgoCD | One app in Docker or kind | Sandbox |
| Secrets from GCP Secret Manager via ExternalSecrets and Workload Identity | `.env` and generated tokens in `.state/`; plain Kubernetes Secrets | No cloud dependency |
| Kargo + ArgoCD promotion of a signed image | `tilt up` | Local development loop |
| Barndoor LLM gateway with Claude subscription passthrough (`ANTHROPIC_CUSTOM_HEADERS: x-api-key`) | Gateway API key in `ANTHROPIC_AUTH_TOKEN`, an Anthropic provider and an `sre-agent` route | A trial has no subscription passthrough set up; the API-key path is simpler |

## Left out

- **Recurrence detection.** Production's first workflow step checks OnCall for
  a recent triage of the same issue and annotates instead of re-triaging.
- **Jira ticketing** through Barndoor's Atlassian connector, including the
  write-confirmation handshake.
- **Code tracing** against a source snapshot baked into the image.
- **Database probes** (read-only SQL through Barndoor's PostgreSQL servers).
- **Self-telemetry** (OTLP metrics per triage) and Slack fallbacks.
- **Run-ledger hardening:** draining in-flight triages on shutdown and
  reconciling stranded runs on boot.

Each of these is an extension of the same pattern: another `sre-*` server
behind a read-only policy, another workflow step, or another small CLI the
director calls.
