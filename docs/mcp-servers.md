# Configure the MCP servers and the SRE agent in Barndoor

> This is reference material. The [setup guides](README.md) walk through the
> servers each example needs, step by step; come here for how they work.

The agent investigates through one MCP server, `barndoor --stdio`, which
fronts every backend Barndoor lets it use. This guide sets up those backends
(Barndoor calls each one an **MCP server**) and the **policies** that decide
which of their tools the agent may call.

| Server slug | Backend | Kind | Used by |
|---|---|---|---|
| `sre-docker` | Docker on your machine | Embedded: runs inside the agent's own `barndoor` CLI | example 01 |
| `sre-grafana` | Your sandbox Grafana | Remote connector: runs in Barndoor's cloud | examples 02, 03 |
| `sre-kubernetes` | The example's kind cluster | Embedded | example 03 |

The slugs matter: the agent's prompts and `scripts/barndoor-smoke.py` expect
exactly these. Barndoor derives a server's slug from its name, so name each
server exactly as shown (`sre-docker`, not "Docker").

Prerequisite: the agent exists and `.env` is filled in
([barndoor-trial-setup.md](barndoor-trial-setup.md)).

## How the pieces fit

```
catalog entry ──instantiate──▶ MCP server ──credentials──▶ connection ──▶ backend
 (directory: "docker",           ("sre-docker",              (who the server acts
  "grafana", "kubernetes")         your org's instance)         as; Grafana only)
                                       │
                                       └── policy: which agents may call which tools
```

- A **catalog entry** (Barndoor's MCP server directory) defines a server type:
  its tools and how it authenticates. Docker and Kubernetes are *embedded*
  entries: the tools execute inside the `barndoor` CLI process on whatever
  machine runs the agent, against that machine's Docker socket or kubeconfig.
  Grafana is a *remote* entry: Barndoor's cloud calls your Grafana's HTTP API.
- An **MCP server** is your organization's instance of an entry.
- A **connection** holds the credential a server uses. Embedded Docker and
  Kubernetes need none (they use the local socket and kubeconfig). Grafana
  needs a service-account token, connected **for the agent** so it acts as
  that service account only when the agent calls it.
- A **policy** binds agents to a server with rules. When an agent has its own
  policy on a server, any tool call no rule allows is **denied**, and
  organization-wide policies for "any agent" do not apply on top. So an
  allowlist of read tools really is a read-only boundary. Rules are ALLOW
  lists; do not add a catch-all `DENY *`, because an explicit deny wins over
  the allows.

Every call, allowed or denied, lands in **Audit history**
(<https://app.barndoor.ai/audit/history>).

## Option A: Terraform (recommended)

Each example's `apply.sh` applies [terraform/modules/barndoor-sre](../terraform/modules/barndoor-sre/main.tf)
with the servers that example needs. It:

- looks up the agent by name (`SRE_AGENT_NAME`; the agent itself stays
  console-managed, so `terraform destroy` never unregisters it or invalidates
  its credentials);
- instantiates the servers from the catalog (`docker`, `grafana`,
  `kubernetes` entries) as `sre-docker`, `sre-grafana`, `sre-kubernetes`;
- creates one ACTIVE policy per server, scoped to the agent, allowing only
  these tools:

| Server | Allowed tools |
|---|---|
| `sre-docker` | `list_containers`, `inspect_container`, `container_logs` |
| `sre-kubernetes` | `list_contexts`, `list_namespaces`, `get_namespace`, `list_pods`, `get_pod`, `get_pod_logs`, `get_pod_metrics`, `list_deployments`, `get_deployment`, `list_services`, `get_service`, `list_events`, `list_object_events`, `get_resource`, `list_resources`, `describe_resource`, `rollout_status`, `rollout_history` |
| `sre-grafana` | `getDataSources`, `getDataSourceByUID`, `getDataSourceByName`, `checkDatasourceHealthWithUID`, `queryMetricsWithExpressions`, `getDashboardByUID`, `getFolders`, `getAnnotations`, plus `postAnnotation` for the director's verdict |

Everything else those servers offer is denied: for Docker that includes
`exec_in_container`, `stop_container`, `remove_container` and image pushes;
for Kubernetes `delete_pod`, `exec_in_pod`, `scale_deployment`,
`restart_deployment`, `apply_resource` and the rest; for Grafana every
dashboard, datasource, folder and team change.

It also runs two `check` blocks that warn (without failing) if the agent's
**LLM Gateway** is off, or if write confirmations would hold the director's
annotation.

Run it per example:

```bash
examples/01-local-queue/apply.sh     # sre-docker            (optional for 01)
examples/02-grafana/apply.sh         # sre-grafana           (+ Grafana config)
examples/03-kubernetes/apply.sh      # sre-grafana + sre-kubernetes
```

Then do the one step Terraform cannot: **connect Grafana for the agent**
([below](#connect-grafana-for-the-agent)).

## Option B: the console

### Add the servers

For each server the example needs, open **MCP Servers → Add**
(<https://app.barndoor.ai/servers/add>), pick the catalog entry, and name it:

| Catalog entry | Name it | Settings |
|---|---|---|
| Docker | `sre-docker` | none |
| Kubernetes | `sre-kubernetes` | none |
| Grafana | `sre-grafana` | **Grafana instance URL**: the tunnel hostname without `https://`, for example `abc-def.trycloudflare.com` (example 02's `up.sh` prints it) |

### Add the policies

Open the Access Control Center (<https://app.barndoor.ai/rules>), select
**SRE Example Agent** in the **AI Agents** column and the server in the
**Connected Servers** column, and allow only the tools in the table above.
Leave everything else unallowed. See
[Managing policies](https://docs.barndoor.ai/how-tos/manage-policies) for the
editor.

## Connect Grafana for the agent

Barndoor's Grafana connector authenticates with a Grafana service-account
token. Examples 02 and 03 create one (`sre-agent`, Editor role, because
Grafana only lets editors create annotations; the Barndoor policy narrows what
the agent can do with it).

1. Get the token:

   ```bash
   terraform -chdir=examples/02-grafana/terraform output -raw grafana_connector_token
   # or examples/03-kubernetes/terraform for example 03
   ```

2. In the console, open **AI Agents → SRE Example Agent**, choose
   **Manage Connections**, find `sre-grafana`, connect it, and paste the token.

Connect it on the **agent**, not organization-wide: the agent's own connection
is what its calls use, and it keeps the token scoped to this one agent.

### Why the tunnel

The Grafana connector runs in Barndoor's cloud, so it cannot reach
`localhost:3000`. Examples 02 and 03 run a Cloudflare quick tunnel
(`cloudflared tunnel --url http://grafana:3000`) that gives the sandbox Grafana
a public HTTPS hostname like `abc-def.trycloudflare.com`. Grafana's API still
requires the service-account token, so the tunnel exposes a login page and an
authenticated API, nothing anonymous.

Quick-tunnel hostnames change whenever the tunnel container or pod restarts.
Re-run the example's `apply.sh`; it reads the new hostname and updates
`sre-grafana`. If you would rather not use a tunnel, point the server at any
Grafana that is reachable from the internet (for example a free Grafana Cloud
stack) and set `grafana_instance` to its hostname.

## Verify

```bash
scripts/barndoor-smoke.py
```

prints the servers the agent can see, and marks the `sre-*` ones:

```
barndoor --stdio authenticated; 3 server(s) visible to this agent:
  - sre-docker
  ...
  ok sre-docker        (used by 01-local-queue)
  -- sre-grafana       (used by 02-grafana, 03-kubernetes)
```

Then make one real call through policy:

```bash
scripts/barndoor-smoke.py --call sre-docker list_containers '{}'
scripts/barndoor-smoke.py --call sre-grafana getDataSources '{}'
```

To see the policy work, try a tool the policy does not allow; Barndoor denies
it and records the denial in Audit history:

```bash
scripts/barndoor-smoke.py --call sre-docker list_images '{}'
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `m2m authentication failed … invalid_client` | `BARNDOOR_CLIENT_ID`/`SECRET` in `.env` are wrong or were rotated |
| An `sre-*` server is missing from `barndoor-smoke.py` | Not created yet, or named differently (its slug comes from the name) |
| `{"status": "warming"}` | The CLI is still starting; the agent and the smoke script retry automatically |
| Grafana calls fail with a connection error | The tunnel hostname changed: re-run `apply.sh` |
| Grafana calls return 401 | The agent's `sre-grafana` connection is missing or has an old token |
| `postAnnotation` waits for approval | Write confirmations are on for the agent; see [trial setup, step 3](barndoor-trial-setup.md#3-create-the-sre-agents-identity) |
