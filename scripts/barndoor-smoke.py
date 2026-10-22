#!/usr/bin/env python3
"""Check the agent's Barndoor credentials the way the agent itself uses them.

Starts `barndoor --stdio` with BARNDOOR_CLIENT_ID / BARNDOOR_CLIENT_SECRET in
its environment, speaks MCP over stdin/stdout, and calls the `list_servers`
meta-tool. Prints the servers this agent can reach and flags the sre-*
servers each example expects.

    scripts/barndoor-smoke.py               (after `set -a; . .env; set +a`)
    scripts/barndoor-smoke.py --call sre-docker list_containers '{}'
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import subprocess
import sys
import time

EXPECTED = {
    "sre-docker": "01-local-queue",
    "sre-grafana": "02-grafana, 03-kubernetes",
    "sre-kubernetes": "03-kubernetes",
}
WARMING_ATTEMPTS = 10
WARMING_DELAY_SECONDS = 3


class Gateway:
    def __init__(self, binary: str, env_name: str) -> None:
        self.proc = subprocess.Popen(
            [binary, "--stdio", "--env", env_name],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.ids = itertools.count(1)
        self.rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "sre-example-smoke", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message: dict) -> None:
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def rpc(self, method: str, params: dict) -> dict:
        message = {"jsonrpc": "2.0", "id": next(self.ids), "method": method, "params": params}
        self.send(message)
        for line in self.proc.stdout:
            try:
                parsed = json.loads(line)
            except ValueError:
                continue
            if parsed.get("id") == message["id"]:
                return parsed
        stderr = self.proc.stderr.read()[-2000:] if self.proc.stderr else ""
        raise RuntimeError(f"barndoor exited during {method}:\n{stderr}")

    def call(self, tool: str, arguments: dict) -> str:
        text = ""
        for _ in range(WARMING_ATTEMPTS):
            response = self.rpc("tools/call", {"name": tool, "arguments": arguments})
            if "error" in response:
                raise RuntimeError(json.dumps(response["error"]))
            content = (response.get("result") or {}).get("content") or [{}]
            text = str(content[0].get("text", ""))
            if '"warming"' not in text:
                return text
            time.sleep(WARMING_DELAY_SECONDS)
        return text

    def close(self) -> None:
        self.proc.terminate()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--call", nargs=3, metavar=("SLUG", "TOOL", "ARGS_JSON"),
                        help="also run one execute_tool call, e.g. sre-docker list_containers '{}'")
    args = parser.parse_args()

    for name in ("BARNDOOR_CLIENT_ID", "BARNDOOR_CLIENT_SECRET"):
        if not os.environ.get(name):
            print(f"error: {name} is not set (fill in .env, then `set -a; . .env; set +a`)", file=sys.stderr)
            return 1
    binary = os.environ.get("BARNDOOR_BIN") or shutil.which("barndoor")
    if not binary:
        print("error: barndoor CLI not found; see docs/barndoor-trial-setup.md", file=sys.stderr)
        return 1

    gateway = Gateway(binary, os.environ.get("BARNDOOR_ENV", "prod"))
    try:
        raw = gateway.call("list_servers", {})
        try:
            servers = json.loads(raw)
        except ValueError:
            print(raw)
            return 1
        if isinstance(servers, dict):
            if servers.get("status") == "error":
                print(f"barndoor --stdio failed: {servers.get('message', raw)}", file=sys.stderr)
                return 1
            servers = servers.get("servers") or servers.get("result") or []
        slugs = sorted(s.get("slug", "?") for s in servers if isinstance(s, dict))
        print(f"barndoor --stdio authenticated; {len(slugs)} server(s) visible to this agent:")
        for slug in slugs:
            print(f"  - {slug}")
        print()
        for slug, examples in EXPECTED.items():
            mark = "ok " if slug in slugs else "-- "
            print(f"  {mark}{slug:<16} (used by {examples})")

        if args.call:
            slug, tool, arguments = args.call
            print(f"\n→ execute_tool({slug}, {tool})")
            print(gateway.call("execute_tool", {"slug": slug, "tool": tool, "args": json.loads(arguments)}))
    finally:
        gateway.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
