# Example 01 setup guide: local queue

This guide takes you from an empty machine to a working SRE agent that
triages alerts from a local app. Follow the steps in order. Each step ends
with a check so you know it worked before you move on.

**What you will have at the end:** a sample app running in Docker, a small
alerter watching it, and the SRE agent running on your machine. When you break
the app, the alerter raises an alert, the agent investigates the app's
container through Barndoor, and it writes an incident record with a verdict.

```
app (Docker) ──/metrics──▶ alerter (Docker) ──POST ingest──▶ bobi event server ──▶ triage
                                                              (your machine)          │
fixtures ──scripts/fire-alert.sh──────────────────────────────▶                       │
                                                       barndoor --stdio ◀─────────────┘
                                                       sre-docker: list, inspect, logs only
```

**Time:** about 45 minutes, most of it the one-time Barndoor setup.

**Already finished another example?** You can skip the steps you have done:
tools in [step 1](#step-1-install-the-tools) and the Barndoor trial, agent and
gateway in [steps 3 to 6](#step-3-create-a-barndoor-trial). Start at
[step 7](#step-7-add-the-docker-server-and-its-policy).

## Contents

1. [Install the tools](#step-1-install-the-tools)
2. [Get the repository and create `.env`](#step-2-get-the-repository-and-create-env)
3. [Create a Barndoor trial](#step-3-create-a-barndoor-trial)
4. [Create the SRE agent's identity](#step-4-create-the-sre-agents-identity)
5. [Give the gateway a model](#step-5-give-the-gateway-a-model)
6. [Create the agent's gateway key](#step-6-create-the-agents-gateway-key)
7. [Add the Docker server and its policy](#step-7-add-the-docker-server-and-its-policy)
8. [Verify the setup](#step-8-verify-the-setup)
9. [Start the app and the alerter](#step-9-start-the-app-and-the-alerter)
10. [Start the agent](#step-10-start-the-agent)
11. [Break the app and watch the triage](#step-11-break-the-app-and-watch-the-triage)
12. [Read the result](#step-12-read-the-result)
13. [Stop everything](#step-13-stop-everything)

[Troubleshooting](#troubleshooting) and [things to try next](#things-to-try-next)
are at the end.

---

## Step 1: Install the tools

You need these on your machine:

| Tool | Why | Install (macOS with Homebrew) |
|---|---|---|
| Python 3.11 or newer | bobi and the helper scripts | `brew install python` |
| uv | installs bobi | `brew install uv` |
| bobi 0.58.0 | the agent runtime | `uv tool install 'bobi==0.58.0'` |
| Node.js 20 or newer | bobi's local event server | `brew install node` |
| Claude Code | the agent's brain | `npm install -g @anthropic-ai/claude-code` |
| Docker | runs the app and the alerter | Docker Desktop, Rancher Desktop or OrbStack |
| barndoor CLI | the agent's gateway to every tool | installed in step 2 |

On Linux, use your package manager for Python, Node and Docker; the `uv`,
`npm` and barndoor commands are the same.

**Check:**

```bash
python3 --version     # 3.11 or newer
bobi --version        # 0.58.0
node --version        # v20 or newer
claude --version
docker info >/dev/null && echo "docker ok"
```

## Step 2: Get the repository and create `.env`

```bash
git clone <this repository> barndoor-sre-agent-example
cd barndoor-sre-agent-example
cp .env.example .env
```

Run every command in this guide from the repository root.

Install the barndoor CLI. The script downloads the release for your platform
and verifies its published SHA-256 checksum before installing it:

```bash
scripts/install-barndoor-cli.sh
```

It installs to `~/.local/bin/barndoor`. If that directory is not on your
`PATH`, open `.env` and set `BARNDOOR_BIN` to the full path.

**Check:** `barndoor version` prints a version.

## Step 3: Create a Barndoor trial

1. Sign up at <https://app.barndoor.ai/auth/signup/trial>.
2. Sign in to the console at <https://app.barndoor.ai>. As the person who
   created the organization, you are its admin, which the next steps need.

**Check:** you can open **AI Agents** at <https://app.barndoor.ai/agents>.

## Step 4: Create the SRE agent's identity

The agent signs in to Barndoor as itself, with machine-to-machine
credentials, not as you. That is what lets policies, budgets and the audit
log name the agent.

1. Open **AI Agents** and click **Add Agent**.
2. Fill in the form:
   - **Name:** `SRE Example Agent`. If you use a different name, set
     `SRE_AGENT_NAME` in `.env` to match.
   - **Description:** for example "Triages Flux Capacitor alerts".
   - Leave the callback and logout URLs empty.
   - Turn on **MCP Connections Enabled**. This makes the agent a
     machine-to-machine client that can hold its own credentials.
   - Turn on **LLM Gateway Enabled**, so its model calls are routed and
     tracked.
3. Click **Register agent**.
4. Barndoor shows the **Client ID** and **Client Secret** once. Copy them into
   `.env`:

   ```bash
   BARNDOOR_CLIENT_ID=...
   BARNDOOR_CLIENT_SECRET=...
   ```

If you lose the secret, rotate it from the agent's page.

**Check:**

```bash
scripts/barndoor-smoke.py
```

It prints `barndoor --stdio authenticated`. It lists no `sre-*` servers yet;
you add one in step 7. If it prints `m2m authentication failed … invalid_client`,
the ID or secret in `.env` is wrong.

## Step 5: Give the gateway a model

The agent's brain is Claude Code pointed at the Barndoor LLM gateway. A trial
starts with no model provider, so add one. You need an Anthropic API key for
the gateway to use upstream.

In the console, follow Barndoor's
[LLM gateway quickstart](https://docs.barndoor.ai/how-tos/llm-gateway-quickstart):

1. Add a credential holding your Anthropic API key.
2. Create a provider of type Anthropic that uses it.
3. Enable a Claude model on the provider, for example `claude-sonnet-5-5`.
4. Optionally create a route named `sre-agent` that serves that model. A
   route lets you change the model later without touching the agent.

Then find the model under **Settings → My Models → Available Models** and copy
its name exactly as shown into `.env`. It is either your route name or a
provider-prefixed name such as `Anthropic/claude-sonnet-5-5`:

```bash
LLM_MODEL=sre-agent
```

> **Prefer Terraform?** `scripts/setup-llm-gateway.sh` does all of this step
> and also adds a daily token budget for the agent. It needs an admin
> Terraform credential first; see
> [example 02, step 7](example-02-grafana.md#step-7-create-a-terraform-credential)
> and [step 8](example-02-grafana.md#step-8-give-the-gateway-a-model).

## Step 6: Create the agent's gateway key

Create a gateway API key bound to the agent, so model usage is attributed to
it:

1. Open **AI Agents → SRE Example Agent**, then the **⋮** menu → **Manage keys**.
2. Click **Create new key**.
3. Copy the `bd-…` key. It is shown once.

If **Manage keys** is not available in your organization, create a key under
**Settings → My Models → API Keys → Create Key** instead. Usage is then
attributed to you rather than the agent.

Put it in `.env`, as the bare key with no `x-api-key:` prefix:

```bash
ANTHROPIC_AUTH_TOKEN=bd-...
```

Leave `LLM_GATEWAY_URL=https://app.barndoor.ai/api/llm-gateway` as it is,
with no trailing `/v1`.

**Check:**

```bash
scripts/check-gateway.sh
```

It ends with `HTTP 200`. A 401 means the key is wrong; a model error means
`LLM_MODEL` does not match a name under **Available Models**.

## Step 7: Add the Docker server and its policy

The agent investigates the app's container through Barndoor's embedded
Docker server. Embedded means its tools run inside the agent's own `barndoor`
CLI process, on your machine, against your local Docker. A policy then limits
the agent to three read tools.

1. Open **MCP Servers → Add** (<https://app.barndoor.ai/servers/add>).
2. Choose **Docker** from the catalog.
3. Name it exactly `sre-docker`. Barndoor derives the server's slug from the
   name, and the agent's prompts look for `sre-docker`.
4. Save. Docker needs no credentials.
5. Open the Access Control Center (<https://app.barndoor.ai/rules>).
6. In the **AI Agents** column, select **SRE Example Agent**. In the
   **Connected Servers** column, select **sre-docker**.
7. On the **Actions** tab, allow only these tools:
   - `list_containers`
   - `inspect_container`
   - `container_logs`
8. Save the policy and make sure it is **Active**.

Every other Docker tool, including `exec_in_container`, `stop_container` and
`remove_container`, is now denied for this agent: once an agent has its own
policy on a server, any tool its rules do not allow is refused.

> **Prefer Terraform?** `examples/01-local-queue/apply.sh` creates the same
> server and policy. It needs the admin Terraform credential described in
> [example 02, step 7](example-02-grafana.md#step-7-create-a-terraform-credential).

**Check:**

```bash
scripts/barndoor-smoke.py
```

The `sre-docker` line is marked `ok`. Then make one real call through the
policy:

```bash
scripts/barndoor-smoke.py --call sre-docker list_containers '{}'
```

## Step 8: Verify the setup

Run the whole pipeline once without spending model tokens. bobi's stub brain
exercises alert intake, dispatch and the workflow without calling a model.

In one terminal:

```bash
scripts/agent-up.sh --stub
```

Wait until it prints `Session 'bobi-sre-director' ready`. In a second
terminal:

```bash
scripts/fire-alert.sh smoke
```

**Check:** the fire command prints `{"delivered_to":1}` and `HTTP 200`. In the
first terminal you see `Auto-dispatching triage`, then the run stops with
`Handoff missing required fields after retries: ['acked']`. That stop is
expected: the stub brain cannot write workflow handoffs. It means everything
up to the model works.

Stop the stub agent with Ctrl-C, then:

```bash
scripts/agent-down.sh
```

## Step 9: Start the app and the alerter

```bash
examples/01-local-queue/up.sh
```

This builds and starts two containers:

- `sre-example-app`, the Flux Capacitor service on <http://localhost:8000>;
- `sre-example-alerter`, which scrapes the app's `/metrics` every 10 seconds
  and evaluates four rules: FluxCapacitorOverload, HighErrorRate, HighLatency
  and FluxCapacitorDown.

**Check:**

```bash
curl -s localhost:8000/                # {"service":"flux-capacitor","status":"time circuits on"}
docker logs sre-example-alerter        # "watching http://app:8000/metrics with 4 rules"
```

## Step 10: Start the agent

In a second terminal:

```bash
scripts/agent-up.sh
```

It checks your settings, installs the agent package from `agent/` into the
repository's `.bobi/` directory, starts bobi's event server on
`localhost:8080`, and waits for alerts. Leave it running.

**Check:** it prints `Session 'bobi-sre-director' ready`.

## Step 11: Break the app and watch the triage

In a third terminal, inject a fault:

```bash
scripts/break-app.sh overload
```

The app's `flux_capacitor_gigawatts` gauge climbs from about 1.0 to about 2.4,
past the 1.21 safety limit, and the app logs
`CHAOS: overload fault enabled via POST /chaos/overload`.

Watch the alerter. After the rule's 30-second window it fires:

```bash
docker logs -f sre-example-alerter
# PENDING FluxCapacitorOverload value=2.35 threshold=1.21
# FIRING FluxCapacitorOverload value=2.39 threshold=1.21
# alert FluxCapacitorOverload-1792523504 delivered (HTTP 200)
```

In the agent's terminal, `Auto-dispatching triage` appears, and the workflow
runs through its steps: `ack`, `investigate`, `post_findings`, then
`deep_dive` if needed, `synthesize` and `conclude`. A triage usually takes a
few minutes.

To follow it in more detail:

```bash
BOBI_HOME=$PWD/.bobi bobi agent sre events     # delivery and dispatch decisions
BOBI_HOME=$PWD/.bobi bobi agent sre status     # running sessions
```

## Step 12: Read the result

The director writes one markdown file per incident:

```bash
ls incidents/
cat incidents/FluxCapacitorOverload-*.md
```

It has this shape (illustrative; the wording varies run to run):

```
# Incident FluxCapacitorOverload-1792523504

## 2026-10-20 19:12:20Z
🔎 ACK — investigating FluxCapacitorOverload (warning, local/docker-compose, service flux-capacitor) ...

## 2026-10-20 19:13:41Z
📊 Findings — container sre-example-app running, 0 restarts; logs show
"CHAOS: overload fault enabled via POST /chaos/overload" at 19:11:31, followed by
"flux capacitor output 2.39 GW exceeds the 1.21 GW safety limit" every 5s ...

## 2026-10-20 19:14:30Z
🚨 FluxCapacitorOverload (local) — overload fault injected via POST /chaos/overload
Impact: output above the safety limit; requests still succeed
Action: clear the fault (POST /chaos/reset) and find who called the chaos endpoint
Escalate: yes — the fix is a write, which this agent never performs
```

Then look at what Barndoor recorded:

- **Audit history** (<https://app.barndoor.ai/audit/history>): each
  `sre-docker` call the agent made, filterable by agent and server.
- **The agent's page** under **AI Agents**: its model calls, tokens and cost
  through the gateway.

## Step 13: Stop everything

```bash
scripts/break-app.sh reset
scripts/agent-down.sh                  # stops the agent and its event server
examples/01-local-queue/down.sh        # stops the app and the alerter
```

Agent state stays in `.bobi/`, `.claude-sre/` and `incidents/` inside the
repository. Delete those directories to start fresh.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `agent-up.sh` says `missing settings: ...` | Fill in the named values in `.env` (steps 4 to 6) |
| `m2m authentication failed … invalid_client` | `BARNDOOR_CLIENT_ID` or `BARNDOOR_CLIENT_SECRET` is wrong or was rotated |
| `sre-docker` is not marked `ok` | The server is missing or named differently; its slug must be `sre-docker` |
| `check-gateway.sh` returns 401 | The `bd-` key is wrong, or has the `x-api-key:` prefix |
| `check-gateway.sh` returns a model error | `LLM_MODEL` must match a name under **Available Models** exactly |
| Alerter logs `ingest unreachable` | The agent is not running, or `SRE_EVENT_PORT` differs between runs |
| Alerter logs `ingest rejected ... HTTP 403` | The agent was started before `.state/ingest-token` changed; restart it with `scripts/agent-up.sh` |
| Nothing happens after `FIRING` | Run `BOBI_HOME=$PWD/.bobi bobi agent sre events` to see whether the event arrived and was dispatched |
| The triage says it could not read logs | Check the `sre-docker` policy allows `container_logs`, and look for a denial in Audit history |
| Port 8080 or 8000 is taken | Set `SRE_EVENT_PORT` in `.env`; stop whatever holds 8000 |

## Things to try next

- **Fire an alert without breaking anything:**
  `scripts/fire-alert.sh flux-capacitor-overload`. There is no fault behind
  it, so a good triage reports that the evidence does not support the alert.
- **Other faults:** `scripts/break-app.sh errors 0.4`, `latency 1.5`, or
  `crash`. Run `scripts/break-app.sh reset` between them.
- **See policy at work:** remove `container_logs` from the `sre-docker` policy
  and break the app again. The agent reports the denied call as a gap, and
  Audit history shows the denial.
- **Add an alert rule:** edit [alerter/rules.json](../alerter/rules.json)
  (kinds `gauge`, `error_ratio`, `avg_latency`, `target_down`) and run
  `docker restart sre-example-alerter`.
- **Move on to [example 02](example-02-grafana.md)**, which replaces the
  alerter with Grafana alerting and Terraform.

## How the alert reaches the agent

The alerter posts each new alert to
`http://host.docker.internal:8080/webhooks/ingest/alert/firing` with
`Authorization: Bearer <token>`. `scripts/lib.sh` generates that token once
per checkout in `.state/ingest-token` and hands it to both sides: to the
alerter through Docker Compose, and to bobi's event server through
`BOBI_ES_INGEST_TOKENS`, which seeds it at startup. No token-minting step is
needed. On macOS, Docker Desktop and Rancher Desktop route
`host.docker.internal` to your machine's loopback. On Linux the script makes
the event server listen on all interfaces so containers can reach it; the
endpoint still requires the token.
