# The SRE agent package

A [bobi](https://github.com/moda-labs/bobi-agent) agent team. Every example
installs this directory unchanged (`bobi agents install agent --name sre`);
only the alert source and the Barndoor servers around it differ.

| File | What it controls |
|---|---|
| [agent.yaml](agent.yaml) | Brain (Claude Code via the Barndoor LLM gateway), the `alert/firing` subscription, the `auto_dispatch` rule that launches `triage`, and the `barndoor --stdio` MCP server |
| [agent.md](agent.md) | Directives every session sees: observability first, never remediate, only the director speaks, cite evidence, all tools through Barndoor |
| [roles/director/ROLE.md](roles/director/ROLE.md) | Acknowledges, records findings, writes the four-line verdict, decides escalation, annotates Grafana |
| [roles/sre/ROLE.md](roles/sre/ROLE.md) | Which `sre-*` servers exist, how to query them, the investigation strategy, the read-only rules |
| [workflows/triage.yaml](workflows/triage.yaml) | `ack → investigate → post_findings → (deep_dive → post_deep_dive) → synthesize → conclude` |
| [tools/barndoor.md](tools/barndoor.md) | How to use Barndoor's meta-tools (`list_servers`, `describe_tools`, `execute_tool`) |
| [bin/sre-note](bin/sre-note) | Appends to `incidents/<incident_id>.md`; the scripts put `bin/` on `PATH` |

Edit any of these and restart the agent (`scripts/agent-up.sh` reinstalls the
package every time; in example 03, Tilt rebuilds the image). Validate a
workflow change without running it:

```bash
BOBI_HOME=$PWD/.bobi bobi agent sre workflows validate .bobi/agents/sre/run/package/workflows/triage.yaml
```

See [docs/architecture.md](../docs/architecture.md#the-agent-package) for the
settings in `agent.yaml` that are easy to get wrong.
