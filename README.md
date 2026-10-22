# Barndoor SRE Agent Example

An AI on-call engineer you can run yourself. A sample service breaks on
demand, an alerting pipeline notices, and an SRE agent investigates each alert
and writes up what it found, with every tool call governed by **Barndoor**
policy and every model call going through the **Barndoor LLM gateway**.

It is a working, simplified version of the SRE agent Barndoor runs against its
own platform, built the same way and wired to Barndoor the same way.

> **Ready to set it up?** Go to the [setup guides](docs/README.md). Each one
> walks every step, from installing tools and creating a Barndoor trial to
> watching the agent triage an alert.

## What the agent does

When an alert fires, the agent runs a fixed triage workflow with two roles:

- the **sre** role investigates: it reads the alert, queries metrics, and
  inspects the service's containers or pods and their logs;
- the **director** role is the only voice to humans: it acknowledges the
  alert, records the findings as they arrive, and closes with a four-line
  verdict and an explicit call on whether a human needs to act.

```
🚨 HighErrorRate (local) — error fault injected via POST /chaos/errors
Impact: about 40% of requests fail with HTTP 500
Action: clear the fault and find who called the chaos endpoint
Escalate: yes — the fix is a write, which this agent never performs
```

The agent never remediates. It investigates and recommends, and Barndoor
enforces that: its policies allow only read tools, plus one write, posting
the verdict as a Grafana annotation.

## How it fits together

```
 flux-capacitor app ──metrics/logs──▶ alert source ──POST /webhooks/ingest/alert/firing──▶ bobi event server
   (POST /chaos/* breaks it)          (01: alerter.py                                      (topic alert/firing)
                                       02/03: Grafana → bridge.py)                               │
                                                                                          auto_dispatch
                                                                                                 ▼
                                                                           triage workflow (bobi + Claude Code)
                                                                              │                     │
                                                          every model call    │                     │   every tool call
                                                                              ▼                     ▼
                                                                Barndoor LLM gateway     barndoor --stdio (MCP gateway)
                                                                 route "sre-agent",       read-only policies:
                                                                 daily token budget       sre-docker · sre-grafana · sre-kubernetes
```

- **The agent** ([agent/](agent/)) is a [bobi](https://github.com/moda-labs/bobi-agent)
  agent team, the framework Barndoor's production agent uses. It is almost
  entirely declarative: `agent.yaml`, two role prompts, and a `triage`
  workflow. Its brain is Claude Code.
- **Alerts** are flat JSON objects posted to bobi's event server on the
  `alert/firing` topic. Every alert source here sends the same fields, so one
  workflow serves every example.
- **Barndoor** is the only way the agent reaches anything. It signs in as its
  own machine-to-machine identity, so every call is attributed to the agent,
  checked against its policies, and recorded in Barndoor's audit history.
- **The incident record** is a markdown file per alert, plus a Grafana
  annotation where Grafana is present.

[docs/architecture.md](docs/architecture.md) covers each piece in detail.

## Three examples, one agent

The examples build on each other. Each adds one production-shaped layer while
the agent stays the same:

| | Alerts come from | The agent investigates with | Runs on | Setup guide |
|---|---|---|---|---|
| **01: local queue** | A small alerter, or a fixture, posted straight onto the agent's queue | Docker container state and logs | Docker plus your machine | [docs/example-01-local-queue.md](docs/example-01-local-queue.md) |
| **02: Grafana** | Grafana alert rules over Prometheus metrics | Grafana metrics, and annotations for the verdict | Docker plus your machine, configured with Terraform | [docs/example-02-grafana.md](docs/example-02-grafana.md) |
| **03: Kubernetes** | Grafana, in-cluster | Grafana plus Kubernetes pods, events and logs | A kind cluster driven by Tilt, the agent as a Deployment | [docs/example-03-kubernetes.md](docs/example-03-kubernetes.md) |

Example 01 is the place to start: it needs no Terraform, Grafana or
Kubernetes, and shows the whole loop of alert, investigation through Barndoor,
and verdict.

## What Barndoor provides here

| Capability | How the example uses it |
|---|---|
| Agent identity | The agent signs in with its own machine-to-machine credentials, not a person's |
| MCP gateway | One MCP server, `barndoor --stdio`, fronts Docker, Grafana and Kubernetes for the agent |
| Policies | Per-server allowlists of read tools; anything else is denied and audited |
| Agent connections | Grafana's service-account token is held for the agent alone |
| LLM gateway | The agent asks for a route named `sre-agent`; the organization decides which model serves it |
| Budgets | A daily token budget caps the agent's model usage |
| Audit history | Every tool call the agent makes, allowed or denied |
| Terraform provider | Servers, policies, gateway provider, route and budget as code |

[docs/barndoor-trial-setup.md](docs/barndoor-trial-setup.md) and
[docs/mcp-servers.md](docs/mcp-servers.md) explain the Barndoor configuration
in depth.

## Repository layout

```
agent/                  the bobi agent package, shared by every example
app/                    flux-capacitor: a FastAPI service with metrics and /chaos endpoints
alerter/                example 01's Grafana-free alert evaluator
bridge/                 Grafana webhook to bobi bridge, for examples 02 and 03
fixtures/               synthetic alerts for scripts/fire-alert.sh
scripts/                start and stop the agent, fire alerts, break the app, checks, installers
terraform/              modules for Barndoor servers and policies, the LLM gateway, and Grafana
examples/               the runnable pieces of each example (compose files, Tiltfile, Terraform roots)
docs/                   setup guides and reference
```

All runtime state stays inside the checkout (`.bobi/`, `.claude-sre/`,
`.state/`, `incidents/`, all gitignored), so the example never touches your
own bobi or Claude Code configuration.

## Relation to Barndoor's production agent

The production agent takes Grafana OnCall alerts through a cloud queue,
investigates across several clusters and databases, writes OnCall notes and
Jira tickets, and is deployed through GitOps. This example keeps the
framework, the workflow shape, the prompt discipline and the Barndoor wiring,
and simplifies the rest. [docs/production-reference.md](docs/production-reference.md)
lists exactly what changed.
