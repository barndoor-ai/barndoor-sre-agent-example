# Example 02: Grafana

The runnable pieces of example 02. **To set it up, follow
[docs/example-02-grafana.md](../../docs/example-02-grafana.md)**, which walks
every step.

| File | What it is |
|---|---|
| [docker-compose.yaml](docker-compose.yaml) | The app, Prometheus, Grafana, the alert bridge and the Cloudflare quick tunnel |
| [prometheus.yml](prometheus.yml) | Prometheus scrape configuration |
| [up.sh](up.sh) / [down.sh](down.sh) | Start and stop the stack; `up.sh` prints Grafana's public hostname |
| [apply.sh](apply.sh), [terraform/](terraform/) | Grafana alerting and dashboard, plus the `sre-grafana` server and the agent's policy in Barndoor |

The agent itself runs on your machine with `scripts/agent-up.sh` from the
repository root.
