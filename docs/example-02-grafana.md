# Example 02 setup guide: Grafana

This guide takes you from an empty machine to the SRE agent triaging real
Grafana alerts. Follow the steps in order; each ends with a check.

**What you will have at the end:** Prometheus scraping the sample app, Grafana
alert rules watching it, and the SRE agent investigating each firing alert
with Grafana metrics through Barndoor. The agent posts its verdict back onto
the Grafana dashboard as an annotation. Terraform configures both Grafana and
your Barndoor organization.

```
app ──▶ Prometheus ──▶ Grafana alert rules ──webhook──▶ bridge ──POST ingest──▶ bobi ──▶ triage
                         ▲    │                                  (your machine)           │
                         │    └── Cloudflare quick tunnel (public HTTPS hostname)         │
                         │                     ▲                                          │
                         │      Barndoor Grafana connector (cloud) ◀── barndoor --stdio ◀─┘
                         └──────────── postAnnotation (the verdict)
```

**Time:** about an hour from scratch, or 20 minutes if you finished example 01.

**Finished example 01?** Skip [steps 1 to 6](#step-1-install-the-tools) except
for installing Terraform, and stop example 01 first:

```bash
scripts/agent-down.sh
examples/01-local-queue/down.sh
```

Both examples use the container name `sre-example-app` and port 8000.

## Contents

1. [Install the tools](#step-1-install-the-tools)
2. [Get the repository and create `.env`](#step-2-get-the-repository-and-create-env)
3. [Create a Barndoor trial](#step-3-create-a-barndoor-trial)
4. [Create the SRE agent's identity](#step-4-create-the-sre-agents-identity)
5. [Let the director annotate without approval](#step-5-let-the-director-annotate-without-approval)
6. [Check the agent's credentials](#step-6-check-the-agents-credentials)
7. [Create a Terraform credential](#step-7-create-a-terraform-credential)
8. [Give the gateway a model](#step-8-give-the-gateway-a-model)
9. [Create the agent's gateway key](#step-9-create-the-agents-gateway-key)
10. [Start the Grafana stack](#step-10-start-the-grafana-stack)
11. [Apply Terraform](#step-11-apply-terraform)
12. [Connect Grafana for the agent](#step-12-connect-grafana-for-the-agent)
13. [Start the agent](#step-13-start-the-agent)
14. [Break the app and watch the triage](#step-14-break-the-app-and-watch-the-triage)
15. [Read the result](#step-15-read-the-result)
16. [Stop everything](#step-16-stop-everything)

---

## Step 1: Install the tools

| Tool | Why | Install (macOS with Homebrew) |
|---|---|---|
| Python 3.11 or newer | bobi and the helper scripts | `brew install python` |
| uv | installs bobi | `brew install uv` |
| bobi 0.58.0 | the agent runtime | `uv tool install 'bobi==0.58.0'` |
| Node.js 20 or newer | bobi's local event server | `brew install node` |
| Claude Code | the agent's brain | `npm install -g @anthropic-ai/claude-code` |
| Docker | runs the app, Prometheus, Grafana, bridge, tunnel | Docker Desktop, Rancher Desktop or OrbStack |
| Terraform 1.6 or newer | configures Grafana and Barndoor | `brew install terraform` |
| barndoor CLI | the agent's gateway to every tool | installed in step 2 |

**Check:**

```bash
python3 --version && bobi --version && node --version && claude --version
terraform version
docker info >/dev/null && echo "docker ok"
```

## Step 2: Get the repository and create `.env`

```bash
git clone <this repository> barndoor-sre-agent-example
cd barndoor-sre-agent-example
cp .env.example .env
scripts/install-barndoor-cli.sh
```

Run every command in this guide from the repository root. The installer puts
`barndoor` in `~/.local/bin` after verifying its checksum; if that is not on
your `PATH`, set `BARNDOOR_BIN` in `.env` to the full path.

**Check:** `barndoor version` prints a version.

## Step 3: Create a Barndoor trial

1. Sign up at <https://app.barndoor.ai/auth/signup/trial>.
2. Sign in to the console at <https://app.barndoor.ai>. You are the
   organization's admin.

## Step 4: Create the SRE agent's identity

1. Open **AI Agents** (<https://app.barndoor.ai/agents>) and click **Add Agent**.
2. Fill in the form:
   - **Name:** `SRE Example Agent` (or set `SRE_AGENT_NAME` in `.env` to your
     name; Terraform finds the agent by it).
   - **Description:** for example "Triages Flux Capacitor alerts".
   - Leave the callback and logout URLs empty.
   - Turn on **MCP Connections Enabled** (machine-to-machine credentials).
   - Turn on **LLM Gateway Enabled**.
3. Click **Register agent**, then copy the **Client ID** and **Client Secret**,
   shown once, into `.env`:

   ```bash
   BARNDOOR_CLIENT_ID=...
   BARNDOOR_CLIENT_SECRET=...
   ```

## Step 5: Let the director annotate without approval

The agent's only write in this example is the director posting its verdict as
a Grafana annotation. Barndoor holds an agent's write calls for human approval
by default, which would stall that step until someone approves it.

On the agent's page, choose **Edit** and turn off write confirmations, or
later, once the policy exists, set `postAnnotation` to **Always Allow** in the
`sre-grafana` policy
([tool confirmations](https://docs.barndoor.ai/how-tos/tool-confirmations)).
The read-only policy you create in step 11 is what bounds the agent either
way.

If you leave confirmations on, the triage still completes; its record notes
that the annotation is waiting for approval. Terraform also warns about it in
step 11.

## Step 6: Check the agent's credentials

```bash
scripts/barndoor-smoke.py
```

**Check:** it prints `barndoor --stdio authenticated`. No `sre-*` servers are
listed yet. `m2m authentication failed … invalid_client` means the ID or
secret is wrong.

## Step 7: Create a Terraform credential

Terraform manages Barndoor as an organization admin, with a credential that is
separate from the agent's.

1. In the console, open **Settings → API Tokens** and find **Terraform
   provider credentials**.
2. Create a credential. Copy its client ID and secret; they are shown once.
3. The same panel shows your organization's provider settings. Copy them too.

Add all of it to `.env`:

```bash
BARNDOOR_TF_CLIENT_ID=...
BARNDOOR_TF_CLIENT_SECRET=...
BARNDOOR_TF_BASE_URL=https://platform.barndoor.ai
BARNDOOR_TF_TOKEN_URL=https://auth.barndoor.ai/realms/.../protocol/openid-connect/token
BARNDOOR_ORGANIZATION_ID=...
```

These use their own names on purpose. The Barndoor Terraform provider would
otherwise read `BARNDOOR_CLIENT_ID` and `BARNDOOR_CLIENT_SECRET`, which in this
repository are the agent's. The scripts pass the admin credential to
Terraform explicitly.

## Step 8: Give the gateway a model

A trial starts with no model provider. This script creates one with
Terraform, plus a route for the agent and a daily token budget. You need an
Anthropic API key for the gateway to use upstream:

```bash
ANTHROPIC_UPSTREAM_API_KEY=sk-ant-... scripts/setup-llm-gateway.sh
```

Review the plan and type `yes`. It creates:

| Resource | What it is |
|---|---|
| `barndoor_llm_connection` | your Anthropic key, stored write-only in Barndoor |
| `barndoor_llm_provider` | an Anthropic provider named `Anthropic SRE Example` |
| `barndoor_llm_model_mapping` | enables `claude-sonnet-5-5` on it (change with `LLM_UPSTREAM_MODEL=...`) |
| `barndoor_llm_model_mapping` | a route named `sre-agent` serving that model |
| `barndoor_llm_token_budget` | 2M tokens a day for the SRE agent, blocking when used up, alerting at 50% and 80% |

Set the route as the agent's model in `.env`:

```bash
LLM_MODEL=sre-agent
```

If you set up a model in the console during example 01 instead, keep that
`LLM_MODEL` and skip the script.

## Step 9: Create the agent's gateway key

1. Open **AI Agents → SRE Example Agent**, then **⋮ → Manage keys**.
2. Click **Create new key** and copy the `bd-…` key (shown once).
3. Put it in `.env`:

   ```bash
   ANTHROPIC_AUTH_TOKEN=bd-...
   ```

If **Manage keys** is not available, create the key under **Settings → My
Models → API Keys → Create Key**.

**Check:**

```bash
scripts/check-gateway.sh
```

It ends with `HTTP 200`.

## Step 10: Start the Grafana stack

```bash
examples/02-grafana/up.sh
```

This starts five containers:

| Container | What it does |
|---|---|
| `sre-example-app` | the Flux Capacitor service, <http://localhost:8000> |
| `sre-example-prometheus` | scrapes the app every 5 seconds, <http://localhost:9090> |
| `sre-example-grafana` | Grafana 11, <http://localhost:3000> |
| `sre-example-bridge` | receives Grafana's alert webhook and forwards alerts to the agent |
| `sre-example-tunnel` | a Cloudflare quick tunnel giving Grafana a public HTTPS hostname |

The tunnel exists because Barndoor's Grafana connector runs in Barndoor's
cloud and cannot reach `localhost`. Grafana's API still requires a token.

**Check:** the script ends by printing the Grafana URL, its admin password
(stored in `.state/grafana-admin-password`), and a public URL like
`https://abc-def.trycloudflare.com`. You can sign in to
<http://localhost:3000> as `admin`.

## Step 11: Apply Terraform

```bash
examples/02-grafana/apply.sh
```

The script reads the tunnel hostname and runs one Terraform plan with two
providers. Review it and type `yes`.

In **Grafana** it creates:

- the Prometheus datasource (uid `prometheus`);
- the "Flux Capacitor" dashboard in an "SRE Example" folder;
- four alert rules: FluxCapacitorOverload, HighErrorRate, HighLatency,
  FluxCapacitorDown;
- a webhook contact point that posts to the bridge with a bearer token, and a
  notification policy routing every alert to it;
- an `sre-agent` service account and token for Barndoor's connector.

In **Barndoor** it creates:

- the `sre-grafana` MCP server, pointed at the tunnel hostname;
- an active policy for SRE Example Agent allowing only `getDataSources`,
  `getDataSourceByUID`, `getDataSourceByName`, `checkDatasourceHealthWithUID`,
  `queryMetricsWithExpressions`, `getDashboardByUID`, `getFolders`,
  `getAnnotations` and `postAnnotation`. Every dashboard, datasource, folder
  and team change is denied.

Terraform also prints a warning if the agent's LLM gateway is off or if write
confirmations would hold the annotation.

**Check:** in Grafana, **Alerting → Alert rules** lists the four rules in the
"SRE Example" folder, all Normal.

## Step 12: Connect Grafana for the agent

Barndoor's Grafana connector needs the service-account token Terraform just
created. This is the one step Terraform cannot do: the connection belongs to
the agent, not the organization.

1. Print the token:

   ```bash
   terraform -chdir=examples/02-grafana/terraform output -raw grafana_connector_token
   ```

2. In the console, open **AI Agents → SRE Example Agent** and choose **Manage
   Connections**.
3. Find `sre-grafana`, connect it, and paste the token.

**Check:**

```bash
scripts/barndoor-smoke.py --call sre-grafana getDataSources '{}'
```

It returns the Prometheus datasource. A connection error means the tunnel
hostname changed (rerun step 11); a 401 means the token was not saved.

## Step 13: Start the agent

In a second terminal:

```bash
scripts/agent-up.sh
```

**Check:** it prints `Session 'bobi-sre-director' ready`.

## Step 14: Break the app and watch the triage

In a third terminal:

```bash
scripts/break-app.sh errors 0.4
```

About 40% of requests now fail with HTTP 500. Then, in order:

1. Within about 10 seconds the HighErrorRate rule turns **Pending** in Grafana.
2. After its 30-second window it turns **Firing**, and after a 10-second group
   wait Grafana posts to the bridge.
3. The bridge logs the forward:

   ```bash
   docker logs -f sre-example-bridge
   # forwarded HighErrorRate as HighErrorRate-a95648cd1255-1792524390 (HTTP 200)
   ```

4. The agent's terminal shows `Auto-dispatching triage`, and the workflow
   runs: `ack`, `investigate`, `post_findings`, then `deep_dive` if needed,
   `synthesize` and `conclude`.

Follow the run with:

```bash
BOBI_HOME=$PWD/.bobi bobi agent sre events
```

Other faults to try, one at a time with `scripts/break-app.sh reset` between:

| Command | Alert | Evidence the agent should find |
|---|---|---|
| `scripts/break-app.sh overload` | FluxCapacitorOverload | the gauge at about 2.4 GW from a specific time |
| `scripts/break-app.sh errors 0.4` | HighErrorRate | about a 40% 5xx ratio |
| `scripts/break-app.sh latency 1.5` | HighLatency | mean latency about 1.5 seconds |
| `scripts/break-app.sh crash` | FluxCapacitorDown, if the restart takes over 20 seconds | `up` dropped to 0 |

## Step 15: Read the result

- **The incident record:** `cat incidents/HighErrorRate-*.md`. It holds the
  acknowledgement, the Grafana findings with the queries behind them, and the
  four-line verdict.
- **The dashboard:** open <http://localhost:3000/d/flux-capacitor>. The
  verdict is a purple annotation on the timeline, tagged `sre-agent`.
- **Audit history** (<https://app.barndoor.ai/audit/history>): every
  `sre-grafana` call the agent made.
- **The agent's page:** model usage through the `sre-agent` route, against
  its daily budget.

In this example the agent sees only Grafana metrics, not the app's logs. To
add them, set `enable_docker = true` on the `barndoor` module in
[examples/02-grafana/terraform/main.tf](../examples/02-grafana/terraform/main.tf)
and rerun step 11.

## Step 16: Stop everything

```bash
scripts/break-app.sh reset
scripts/agent-down.sh
examples/02-grafana/down.sh            # add -v to also delete Grafana's data
```

Stop the stack when you are done: the tunnel exposes Grafana's login page for
as long as it runs.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `apply.sh` says `missing settings: BARNDOOR_TF_...` | Fill in the Terraform credential from step 7 |
| `apply.sh` says no `trycloudflare.com` hostname | The tunnel is still starting; `docker logs sre-example-tunnel`, then retry |
| `sre-grafana` calls fail to connect | The tunnel restarted with a new hostname; rerun `examples/02-grafana/apply.sh` |
| `sre-grafana` calls return 401 | Redo step 12 with the current token |
| A rule never fires | In Grafana, open the rule and check its query returns data; check Prometheus at <http://localhost:9090/targets> |
| Bridge logs `skip ...: it fired because its query errored` | The rule's query failed; fix the datasource, the bridge skips such alerts on purpose |
| Bridge logs `ingest failed` | The agent is not running (step 13) |
| The verdict is in `incidents/` but not on the dashboard | Write confirmations are holding `postAnnotation` (step 5); check Audit history |

For everything else, see [example 01's troubleshooting](example-01-local-queue.md#troubleshooting),
which covers the agent and gateway.

## Next

[Example 03](example-03-kubernetes.md) runs this same stack, and the agent
itself, in a Kubernetes cluster with Tilt.
