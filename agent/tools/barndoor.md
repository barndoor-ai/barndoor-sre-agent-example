# barndoor: the governed MCP gateway

Every investigation tool reaches its backend through the single `barndoor`
MCP server. It is an **aggregator**: you call meta-tools that route to
backend servers, and Barndoor enforces the organization's policy on every
call and records it in the audit log.

## Meta-tools

- `list_servers()`: the backend servers this agent can reach, with their
  slugs. Call it once at the start of an investigation.
- `search_tools(query)`: find tools by keyword across connected servers.
- `describe_tools(tools=[{"slug": ..., "tool": ...}])`: the input schema for
  specific tools. Use it before calling a tool you have not used before.
- `execute_tool(slug, tool, args)`: run one tool on one backend server. This
  is the workhorse.

## Calling discipline

- **Slugs come from `list_servers`.** This deployment names its servers
  `sre-docker`, `sre-grafana`, and `sre-kubernetes`; confirm which exist.
- **Always pass `kube_context`** on Kubernetes calls.
- **Read only.** This agent's policy allows read tools (plus Grafana
  annotations for the director). Write calls are denied by policy and also
  violate the do-not-remediate directive.
- **Warming:** right after startup a server may answer
  `{"status": "warming"}`. Wait a few seconds and retry once.
- **Denials and errors are data.** A response saying the call was denied by
  policy, or that a server is not connected, goes in your `gaps`. Do not try
  an equivalent call through a different server or the shell.

## Examples

    execute_tool(slug="sre-docker", tool="container_logs",
                 args={"container_id": "sre-example-app", "tail": "200"})

    execute_tool(slug="sre-docker", tool="inspect_container",
                 args={"container_id": "sre-example-app"})

    execute_tool(slug="sre-kubernetes", tool="list_pods",
                 args={"namespace": "sre-demo", "kube_context": "sre-sandbox"})
