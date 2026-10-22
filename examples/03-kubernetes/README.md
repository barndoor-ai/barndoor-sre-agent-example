# Example 03: Kubernetes with Tilt

The runnable pieces of example 03. **To set it up, follow
[docs/example-03-kubernetes.md](../../docs/example-03-kubernetes.md)**, which
walks every step.

| File | What it is |
|---|---|
| [cluster-up.sh](cluster-up.sh) | Creates the kind cluster `sre-example` |
| [Tiltfile](Tiltfile) | Builds the images, creates the Secrets from `.env`, deploys everything, port-forwards |
| [k8s/](k8s/) | Manifests: app, Prometheus, Grafana and tunnel, the bridge, and the agent (ServiceAccount, read-only ClusterRole, PVC, Deployment, Service) |
| [agent-image/](agent-image/) | The agent's image (bobi, Claude Code, barndoor CLI, the agent package) and its entrypoint |
| [apply.sh](apply.sh), [terraform/](terraform/) | Grafana alerting and dashboard, plus the `sre-grafana` and `sre-kubernetes` servers and the agent's policies in Barndoor |
