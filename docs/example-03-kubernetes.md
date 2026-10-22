# Example 03 setup guide: Kubernetes with Tilt

This guide takes you from an empty machine to the whole stack, including the
SRE agent, running in a local Kubernetes cluster. Follow the steps in order;
each ends with a check.

**What you will have at the end:** a kind cluster running the sample app,
Prometheus, Grafana, the alert bridge and the SRE agent, all built and
deployed by Tilt. The agent runs as a Deployment shaped like Barndoor's
production one and investigates with both Grafana and Kubernetes through
Barndoor, behind read-only policies and a read-only ClusterRole.

```
kind cluster "sre-example", namespace sre-demo
┌──────────────────────────────────────────────────────────────────────────────────┐
│ flux-capacitor ─▶ prometheus ─▶ grafana ─webhook─▶ bridge ─▶ sre-agent :8080      │
│                                    ▲                          (bobi + Claude Code │
│                                  tunnel                        + barndoor CLI)    │
└────────────────────────────────────┼──────────────────────────────────┬──────────┘
                                     │                                  │
                  Barndoor Grafana connector ◀────── barndoor --stdio ──┤ sre-grafana
                                                     embedded Kubernetes┘ sre-kubernetes
                                                     (in-pod kubeconfig, read-only service account)
```

**Time:** about an hour from scratch; the first agent image build alone takes
several minutes.

**Finished example 02?** Skip [steps 3 to 9](#step-3-create-a-barndoor-trial):
your agent, Terraform credential, gateway model and key are already in `.env`.
Stop example 02 first, since it uses the same ports:

```bash
scripts/agent-down.sh
examples/02-grafana/down.sh
```

## Contents

1. [Install the tools](#step-1-install-the-tools)
2. [Get the repository and create `.env`](#step-2-get-the-repository-and-create-env)
3. [Create a Barndoor trial](#step-3-create-a-barndoor-trial)
4. [Create the SRE agent's identity](#step-4-create-the-sre-agents-identity)
5. [Let the director annotate without approval](#step-5-let-the-director-annotate-without-approval)
6. [Create a Terraform credential](#step-6-create-a-terraform-credential)
7. [Give the gateway a model](#step-7-give-the-gateway-a-model)
8. [Create the agent's gateway key](#step-8-create-the-agents-gateway-key)
9. [Check the agent's credentials and gateway](#step-9-check-the-agents-credentials-and-gateway)
10. [Create the cluster](#step-10-create-the-cluster)
11. [Bring the stack up with Tilt](#step-11-bring-the-stack-up-with-tilt)
12. [Apply Terraform](#step-12-apply-terraform)
13. [Connect Grafana for the agent](#step-13-connect-grafana-for-the-agent)
14. [Break the app and watch the triage](#step-14-break-the-app-and-watch-the-triage)
15. [Read the result](#step-15-read-the-result)
16. [Tear down](#step-16-tear-down)

---

## Step 1: Install the tools

bobi, Claude Code, Node and the barndoor CLI are baked into the agent's
container image, so you need fewer tools on your machine than in examples 01
and 02. Steps 6 to 9 still run two helper scripts locally, which use Python
and the barndoor CLI.

| Tool | Why | Install (macOS with Homebrew) |
|---|---|---|
| Docker | builds images and hosts the kind cluster | Docker Desktop, Rancher Desktop or OrbStack |
| kind | the local Kubernetes cluster | `brew install kind` |
| kubectl | talks to the cluster | `brew install kubectl` |
| Tilt | builds, deploys and watches everything | `brew install tilt` |
| Terraform 1.6 or newer | configures Grafana and Barndoor | `brew install terraform` |
| Python 3.11 or newer | helper scripts | `brew install python` |
| barndoor CLI | the credential check in step 9 | installed in step 2 |

Give Docker at least 4 CPUs and 8 GB of memory; the agent pod alone requests
1 GB.

**Check:**

```bash
docker info >/dev/null && echo "docker ok"
kind version && kubectl version --client && tilt version && terraform version
python3 --version
```

## Step 2: Get the repository and create `.env`

```bash
git clone <this repository> barndoor-sre-agent-example
cd barndoor-sre-agent-example
cp .env.example .env
scripts/install-barndoor-cli.sh
```

Unless a step says otherwise, run commands from the repository root.

## Step 3: Create a Barndoor trial

1. Sign up at <https://app.barndoor.ai/auth/signup/trial>.
2. Sign in to the console at <https://app.barndoor.ai>. You are the
   organization's admin.

## Step 4: Create the SRE agent's identity

1. Open **AI Agents** (<https://app.barndoor.ai/agents>) and click **Add Agent**.
2. Fill in the form:
   - **Name:** `SRE Example Agent` (or set `SRE_AGENT_NAME` in `.env` to match).
   - **Description:** for example "Triages Flux Capacitor alerts".
   - Leave the callback and logout URLs empty.
   - Turn on **MCP Connections Enabled**.
   - Turn on **LLM Gateway Enabled**.
3. Click **Register agent** and copy the **Client ID** and **Client Secret**,
   shown once, into `.env`:

   ```bash
   BARNDOOR_CLIENT_ID=...
   BARNDOOR_CLIENT_SECRET=...
   ```

## Step 5: Let the director annotate without approval

The director posts its verdict as a Grafana annotation, the agent's only
write. On the agent's page choose **Edit** and turn off write confirmations,
or after step 12 set `postAnnotation` to **Always Allow** in the `sre-grafana`
policy. Otherwise the annotation waits for a human to approve it.

## Step 6: Create a Terraform credential

1. In the console, open **Settings → API Tokens → Terraform provider
   credentials** and create a credential.
2. Copy its client ID and secret (shown once) and the provider settings the
   panel shows, into `.env`:

   ```bash
   BARNDOOR_TF_CLIENT_ID=...
   BARNDOOR_TF_CLIENT_SECRET=...
   BARNDOOR_TF_BASE_URL=https://platform.barndoor.ai
   BARNDOOR_TF_TOKEN_URL=https://auth.barndoor.ai/realms/.../protocol/openid-connect/token
   BARNDOOR_ORGANIZATION_ID=...
   ```

## Step 7: Give the gateway a model

A trial starts with no model provider. Create one, a `sre-agent` route, and a
daily token budget for the agent, using your Anthropic API key upstream:

```bash
ANTHROPIC_UPSTREAM_API_KEY=sk-ant-... scripts/setup-llm-gateway.sh
```

Review the plan, type `yes`, then set in `.env`:

```bash
LLM_MODEL=sre-agent
```

## Step 8: Create the agent's gateway key

1. Open **AI Agents → SRE Example Agent → ⋮ → Manage keys**.
2. Click **Create new key** and copy the `bd-…` key (shown once).
3. In `.env`:

   ```bash
   ANTHROPIC_AUTH_TOKEN=bd-...
   ```

If **Manage keys** is not available, use **Settings → My Models → API Keys →
Create Key**.

## Step 9: Check the agent's credentials and gateway

```bash
scripts/barndoor-smoke.py     # barndoor --stdio authenticated
scripts/check-gateway.sh      # HTTP 200
```

Both must pass before you continue; the agent pod uses exactly these values.

## Step 10: Create the cluster

```bash
cd examples/03-kubernetes
./cluster-up.sh
```

This creates the kind cluster `sre-example` and switches `kubectl` to the
`kind-sre-example` context. The Tiltfile allows only that context, so Tilt
refuses to deploy to any other cluster, including production ones.

Run the remaining steps from `examples/03-kubernetes` unless noted.

**Check:** `kubectl get nodes` shows one `Ready` node.

## Step 11: Bring the stack up with Tilt

```bash
tilt up
```

Press space to open the Tilt UI in your browser. Tilt reads `.env` and the
generated tokens, then:

- builds two images: the app, and the agent (bobi, Claude Code, the barndoor
  CLI and the `agent/` package; the first build takes several minutes);
- creates the `sre-demo` namespace and two Secrets (the agent's settings, and
  the bridge, ingest and Grafana admin tokens);
- deploys `flux-capacitor`, `prometheus`, `grafana`, `tunnel`, `bridge` and
  `sre-agent`;
- port-forwards the app to <http://localhost:8000>, Prometheus to
  <http://localhost:9090>, and Grafana to <http://localhost:3000>.

**Check:** every resource in the Tilt UI turns green. The `sre-agent` log
shows `kubeconfig written (context sre-sandbox)` and then `Session
'bobi-sre-director' ready`. The `grafana-public-url` resource shows a hostname
like `https://abc-def.trycloudflare.com`.

> **No model calls yet?** Start Tilt as `BRAIN_KIND=stub BOBI_STUB_BRAIN=1 tilt up`
> to check the wiring with bobi's stub brain first. A fired alert then stops
> at `Handoff missing required fields after retries: ['acked']`, which is the
> expected end of a stub run.

## Step 12: Apply Terraform

In a second terminal, from `examples/03-kubernetes`:

```bash
./apply.sh
```

The script checks that Grafana answers on `localhost:3000`, reads the tunnel
hostname from the tunnel pod, and runs one Terraform plan. Review it and type
`yes`.

In **Grafana** (through Tilt's port-forward) it creates the Prometheus
datasource, the Flux Capacitor dashboard, the four alert rules (labelled
`environment=kind`, `namespace=sre-demo`), the webhook contact point to the
bridge's in-cluster Service, the notification policy, and the `sre-agent`
service account and token.

In **Barndoor** it creates:

- `sre-grafana`, pointed at the tunnel hostname, with a policy allowing the
  agent only Grafana read tools and `postAnnotation`;
- `sre-kubernetes`, the embedded Kubernetes server, with a policy allowing the
  agent only read tools: `list_contexts`, `list_namespaces`, `get_namespace`,
  `list_pods`, `get_pod`, `get_pod_logs`, `get_pod_metrics`,
  `list_deployments`, `get_deployment`, `list_services`, `get_service`,
  `list_events`, `list_object_events`, `get_resource`, `list_resources`,
  `describe_resource`, `rollout_status` and `rollout_history`.

**Check:** in Grafana (<http://localhost:3000>, user `admin`, password in
`.state/grafana-admin-password`), **Alerting → Alert rules** lists four rules.

## Step 13: Connect Grafana for the agent

1. Print the connector token:

   ```bash
   terraform -chdir=terraform output -raw grafana_connector_token
   ```

2. In the console, open **AI Agents → SRE Example Agent → Manage
   Connections**, find `sre-grafana`, connect it, and paste the token.

**Check** (from the repository root):

```bash
scripts/barndoor-smoke.py --call sre-grafana getDataSources '{}'
```

## Step 14: Break the app and watch the triage

From the repository root:

```bash
scripts/break-app.sh errors 0.4
```

Within about a minute, HighErrorRate fires in Grafana, the `bridge` log in
Tilt shows `forwarded HighErrorRate as ...`, and the `sre-agent` log shows
`Auto-dispatching triage` followed by the workflow steps.

Inside the pod the agent can also reach Kubernetes. Try a crash to give it
pod evidence:

```bash
scripts/break-app.sh crash        # repeat a few times
```

Kubernetes restarts the pod each time; the agent can read the restart count
and events through `sre-kubernetes`.

## Step 15: Read the result

- **The incident record**, on the agent's persistent volume:

  ```bash
  kubectl -n sre-demo exec deploy/sre-agent -- sh -c 'cat /data/incidents/*.md'
  ```

- **The dashboard:** <http://localhost:3000/d/flux-capacitor>, where the
  verdict is a purple annotation.
- **Audit history** (<https://app.barndoor.ai/audit/history>): every
  `sre-grafana` and `sre-kubernetes` call the agent made.

## Step 16: Tear down

```bash
scripts/break-app.sh reset          # from the repository root
cd examples/03-kubernetes
tilt down
kind delete cluster --name sre-example
```

---

## How the agent runs in the pod

The image's [entrypoint](../examples/03-kubernetes/agent-image/entrypoint.sh)
is adapted from the production agent's:

1. It checks the required settings from the `sre-agent` Secret.
2. It writes a kubeconfig whose only context, `sre-sandbox`, points at the
   cluster API with the pod's own service-account token. The barndoor CLI's
   embedded Kubernetes server reads it; the bridge stamps
   `kube_context=sre-sandbox` on every alert so the agent passes it on each
   call.
3. It seeds Claude Code's workspace trust for the agent's run directory.
   Without it, headless Claude Code runs every turn without tools.
4. It reinstalls the agent package from the image, so a new image replaces the
   package on the persistent volume.
5. It runs `bobi agent sre start --foreground`. bobi's event server listens on
   `0.0.0.0:8080` behind the `sre-agent` Service, where the bridge posts
   alerts.

The service account is bound to the `sre-agent-readonly` ClusterRole, which
grants only `get`, `list` and `watch`. Barndoor's policy already limits the
agent to read tools; RBAC means even a policy mistake cannot change the
cluster.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Tilt says `Refusing to run ... might be a production kube context` | Your context is not `kind-sre-example`; run `./cluster-up.sh` |
| Tilt fails with `missing settings in .env` | Fill in steps 4 to 8, or run with `BRAIN_KIND=stub BOBI_STUB_BRAIN=1` |
| `sre-agent` pod restarts with `missing BARNDOOR_CLIENT_ID` | `.env` was empty when Tilt started; fix it and restart `tilt up` |
| `apply.sh` says Grafana is not reachable | Wait for the `grafana` resource to turn green in Tilt |
| `sre-grafana` calls fail to connect | The tunnel pod restarted with a new hostname; rerun `./apply.sh` |
| Alert rules are gone | The Grafana pod restarted (it keeps no state); rerun `./apply.sh` |
| `bridge` logs `ingest failed` | The `sre-agent` pod is not ready yet; check its log in Tilt |
| The agent reports `sre-kubernetes` errors | Check its log for `kubeconfig written`, and that the agent passes `kube_context=sre-sandbox` |

Tilt reads `.env` only at startup: restart `tilt up` after changing it. For
agent and gateway problems, see
[example 01's troubleshooting](example-01-local-queue.md#troubleshooting).
