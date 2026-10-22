# Example 01: local queue

The runnable pieces of example 01. **To set it up, follow
[docs/example-01-local-queue.md](../../docs/example-01-local-queue.md)**,
which walks every step.

| File | What it is |
|---|---|
| [docker-compose.yaml](docker-compose.yaml) | The sample app and the alerter |
| [up.sh](up.sh) / [down.sh](down.sh) | Start and stop them with the generated ingest token |
| [apply.sh](apply.sh), [terraform/](terraform/) | Optional: create the `sre-docker` server and the agent's read-only policy with Terraform instead of the console |

The agent itself runs on your machine with `scripts/agent-up.sh` from the
repository root.
