# Documentation

## Setup guides

Each guide is complete on its own: it starts from an empty machine and walks
every step to a working triage, including the Barndoor trial setup. If you
have finished an earlier guide, each one tells you which steps to skip.

| Guide | You end up with |
|---|---|
| [Example 01: local queue](example-01-local-queue.md) | The app and a small alerter in Docker; the agent on your machine reading container logs through Barndoor |
| [Example 02: Grafana](example-02-grafana.md) | Prometheus and Grafana alerting; the agent querying Grafana through Barndoor and annotating the dashboard; Terraform for Grafana and Barndoor |
| [Example 03: Kubernetes with Tilt](example-03-kubernetes.md) | Everything, the agent included, in a kind cluster deployed by Tilt; the agent reading pods and events through Barndoor |

Start with example 01 unless you already know bobi and Barndoor.

## Reference

| Document | Covers |
|---|---|
| [Barndoor trial setup](barndoor-trial-setup.md) | The trial, the agent's identity, the LLM gateway and the Terraform credential, in more depth than the guides |
| [MCP servers and policies](mcp-servers.md) | How catalog entries, servers, connections and policies fit together; the console and Terraform paths for each `sre-*` server |
| [Architecture](architecture.md) | Components, the end-to-end flow, the alert payload contract, the agent package, and every governance control |
| [Production reference](production-reference.md) | How this example maps to Barndoor's production SRE agent |
