# Set up a Barndoor trial for the SRE agent

> This is reference material. The [setup guides](README.md) walk through
> these steps in order for each example; come here for more detail.

This guide takes you from no Barndoor account to a filled-in `.env` that every
example uses. It has five parts:

1. [Create the trial organization](#1-create-the-trial-organization)
2. [Install the barndoor CLI](#2-install-the-barndoor-cli)
3. [Create the SRE agent's identity](#3-create-the-sre-agents-identity)
4. [Give the agent a model through the LLM gateway](#4-give-the-agent-a-model-through-the-llm-gateway)
5. [Create a Terraform credential](#5-create-a-terraform-credential-examples-02-and-03) (examples 02 and 03)

Then [verify everything](#6-verify) before running an example. Configuring the
MCP servers the agent investigates with is covered in
[mcp-servers.md](mcp-servers.md).

Throughout, "the console" means the Barndoor web app at
<https://app.barndoor.ai>. Official reference: <https://docs.barndoor.ai>
(start with the [trial guide](https://docs.barndoor.ai/how-tos/trial-guide)).

---

## 1. Create the trial organization

1. Sign up at <https://app.barndoor.ai/auth/signup/trial>.
2. Sign in. You are the organization's admin, which every step below needs.

Copy the template that the rest of this guide fills in:

```bash
cp .env.example .env
```

## 2. Install the barndoor CLI

The agent reaches every tool through `barndoor --stdio`, Barndoor's MCP
gateway. Install it with the bundled script, which downloads the release for
your platform and verifies its published SHA-256 checksum:

```bash
scripts/install-barndoor-cli.sh            # installs ~/.local/bin/barndoor
barndoor version
```

If `~/.local/bin` is not on your `PATH`, set `BARNDOOR_BIN` in `.env` to the
binary's absolute path.

## 3. Create the SRE agent's identity

The agent authenticates to Barndoor as itself, with machine-to-machine (M2M)
credentials, not as you. That is what lets policies, connections, budgets and
the audit log all name the agent.

1. In the console, open **AI Agents** (<https://app.barndoor.ai/agents>) and
   click **Add Agent**.
2. Fill in the form:
   - **Name:** `SRE Example Agent` (if you choose another name, set
     `SRE_AGENT_NAME` in `.env` to match, because Terraform looks the agent up
     by name).
   - **Description:** for example "Triages Flux Capacitor alerts (example repo)".
   - Leave the callback and logout URLs empty; this agent never signs a user in.
   - Turn on **MCP Connections Enabled**. This makes it a machine-to-machine
     agent that can hold its own credentials for MCP servers.
   - Turn on **LLM Gateway Enabled** so its model calls can be routed and
     tracked.
3. Click **Register agent**. Barndoor shows the agent's **Client ID** and
   **Client Secret** once. Copy both into `.env`:

   ```bash
   BARNDOOR_CLIENT_ID=...
   BARNDOOR_CLIENT_SECRET=...
   ```

   If you lose the secret, rotate it from the agent's page.

> If you enable the toggles later from the agent's **Edit** action instead,
> the same two settings appear there.

**Write confirmations.** By default Barndoor holds an agent's write tool calls
until a human confirms them. This agent's only write is the director posting
its verdict as a Grafana annotation (examples 02 and 03). For unattended
triage, allow that one tool without confirmation, either by turning off write
confirmations for the agent or by setting `postAnnotation` to **Always Allow**
in its policy ([tool confirmations](https://docs.barndoor.ai/how-tos/tool-confirmations)).
The read-only policies in [mcp-servers.md](mcp-servers.md) are what bound the
agent either way. If you leave confirmations on, triage still completes; the
annotation step reports that it is waiting for approval.

## 4. Give the agent a model through the LLM gateway

The agent's brain is Claude Code pointed at the Barndoor LLM gateway, so every
model call is routed, logged, attributed to the agent, and subject to budgets.
A trial organization starts with **no LLM provider configured**, so you add
one, expose a model, and give the agent a key.

You can do the provider and model part with Terraform (recommended; it also
adds a daily token budget for the agent) or in the console.

### Option A: Terraform

Needs the Terraform credential from [step 5](#5-create-a-terraform-credential-examples-02-and-03)
in `.env` first, plus an Anthropic API key for the gateway to use upstream:

```bash
ANTHROPIC_UPSTREAM_API_KEY=sk-ant-... scripts/setup-llm-gateway.sh
```

This applies [terraform/llm-gateway](../terraform/llm-gateway/main.tf), which
creates:

| Resource | What it is |
|---|---|
| `barndoor_llm_connection` | Your Anthropic key, stored write-only in Barndoor's secret store |
| `barndoor_llm_provider` | An Anthropic provider named `Anthropic SRE Example` using that connection |
| `barndoor_llm_model_mapping` (model) | Enables `claude-sonnet-5-5` on that provider |
| `barndoor_llm_model_mapping` (route) | A route named **`sre-agent`** that serves it; this is what the agent asks for |
| `barndoor_llm_token_budget` | A daily 2M-token budget scoped to the SRE agent, blocking when exhausted, alerting at 50% and 80% |

Set a different upstream model with `LLM_UPSTREAM_MODEL=...`. Because the
agent calls the route name, you can later change the model behind `sre-agent`
without touching the agent.

### Option B: the console

Follow the [LLM gateway quickstart](https://docs.barndoor.ai/how-tos/llm-gateway-quickstart):
add your Anthropic credential, create a provider with it, enable a Claude
model, and (optionally) create a route. Then note the model's name exactly as
it appears under **Available Models**: either your route name or a
provider-prefixed name such as `Anthropic/claude-sonnet-5-5` (everything
before the first `/` is read as the provider's name).

### The agent's gateway key

Create a gateway API key **bound to the agent**, so its usage is attributed to
it and agent-scoped budgets apply:

1. Open the agent under **AI Agents**, then the **⋮** menu → **Manage keys**.
2. Click **Create new key**. The new key is bound to this agent.
3. Copy the `bd-…` key; it is shown once.

If **Manage keys** is not available in your organization, create a key under
**Settings → My Models → API Keys → Create Key** instead (usage is then
attributed to you, not the agent).

Fill in `.env`:

```bash
LLM_GATEWAY_URL=https://app.barndoor.ai/api/llm-gateway   # no trailing /v1
LLM_MODEL=sre-agent                                       # or the name from Available Models
ANTHROPIC_AUTH_TOKEN=bd-...                               # the bare key, no "x-api-key:" prefix
```

How these reach Claude Code: bobi sets `ANTHROPIC_BASE_URL` from
`LLM_GATEWAY_URL`, blanks any `ANTHROPIC_API_KEY` in your environment so a
real Anthropic key can never be sent to the gateway, and Claude Code
authenticates with `ANTHROPIC_AUTH_TOKEN`.

## 5. Create a Terraform credential (examples 02 and 03)

Terraform manages Barndoor as an organization admin, with a credential that is
separate from the agent's:

1. In the console, open **Settings → API Tokens** and find **Terraform
   provider credentials**.
2. Create a credential and copy the client ID and secret (shown once).
3. The same panel shows the provider settings for your organization. Copy
   them into `.env`:

   ```bash
   BARNDOOR_TF_CLIENT_ID=...
   BARNDOOR_TF_CLIENT_SECRET=...
   BARNDOOR_TF_BASE_URL=https://platform.barndoor.ai
   BARNDOOR_TF_TOKEN_URL=https://auth.barndoor.ai/realms/.../protocol/openid-connect/token
   BARNDOOR_ORGANIZATION_ID=...
   ```

> **Why separate variables?** The Barndoor Terraform provider reads
> `BARNDOOR_CLIENT_ID`/`BARNDOOR_CLIENT_SECRET` from the environment by
> default, and in this repo those hold the *agent's* credentials. The example
> scripts pass the admin credential to Terraform explicitly as `TF_VAR_*`
> values, and every provider block sets its fields explicitly, so the two can
> never be mixed up.

## 6. Verify

```bash
scripts/barndoor-smoke.py      # the agent's credentials work; lists servers it can see
scripts/check-gateway.sh       # one small model call through the gateway as the agent
```

`barndoor-smoke.py` should print `barndoor --stdio authenticated`. Until you
configure MCP servers it lists none of the `sre-*` servers; that is next, in
[mcp-servers.md](mcp-servers.md). If it prints
`m2m authentication failed … invalid_client`, the client ID or secret in
`.env` is wrong.

`check-gateway.sh` should end with `HTTP 200`. A 401 means the `bd-` key is
wrong; a 404 or model error means `LLM_MODEL` does not match a name under
**Available Models**.

When both pass, continue with the [example 01 guide](example-01-local-queue.md).

## Where to see what the agent did

- **Audit history** (<https://app.barndoor.ai/audit/history>): every MCP tool
  call the agent made, allowed or denied, filterable by agent and server.
- **LLM usage**: the agent's model calls, tokens and cost, under the agent's
  page and the LLM usage dashboard.
