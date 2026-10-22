"""Grafana alert webhook -> bobi ingest bridge.

Production runs Grafana -> Grafana OnCall -> a Cloudflare Worker -> a queue ->
a queue-bridge sidecar -> bobi. This bridge collapses that chain into one hop
and keeps the parts that matter to the agent:

  * authenticate the sender (shared bearer token on the contact point);
  * flatten each firing alert to top-level primitive fields, because bobi only
    copies those into the workflow's ${{input.*}} scope;
  * skip alerts that fired because their query errored (the agent cannot
    triage a broken query; production skips these too);
  * suppress duplicate notifications of the same firing;
  * forward to the event server's ingest webhook and report the outcome.

    POST /grafana     Grafana webhook contact point target
    GET  /healthz

Standard library only.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("bridge")

LISTEN_PORT = int(os.environ.get("BRIDGE_PORT", "9095"))
BRIDGE_TOKEN = os.environ.get("BRIDGE_TOKEN", "")
INGEST_URL = os.environ.get("BOBI_INGEST_URL", "http://localhost:8080/webhooks/ingest/alert/firing")
INGEST_TOKEN = os.environ.get("BOBI_INGEST_TOKEN", "")
KUBE_CONTEXT = os.environ.get("KUBE_CONTEXT", "")
DEDUP_SECONDS = int(os.environ.get("DEDUP_SECONDS", "3600"))
MAX_BODY_BYTES = 1024 * 1024

DASHBOARD_UID_IN_URL = re.compile(r"/d/([^/?]+)")

_seen: dict[str, float] = {}
_seen_lock = threading.Lock()


def epoch(timestamp: str) -> int:
    try:
        return int(datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp())
    except (ValueError, AttributeError):
        return int(time.time())


def first_value(values: dict | None) -> float | str:
    """The query value behind the alert: refId A by convention, else any."""
    if not values:
        return ""
    if "A" in values:
        return values["A"]
    return next(iter(values.values()))


def flatten(alert: dict, common_labels: dict) -> dict:
    labels = {**common_labels, **(alert.get("labels") or {})}
    annotations = alert.get("annotations") or {}
    alertname = labels.get("alertname", "UnknownAlert")
    started = alert.get("startsAt", "")
    fingerprint = alert.get("fingerprint") or alertname
    dashboard_uid = annotations.get("dashboard_uid", "")
    if not dashboard_uid:
        match = DASHBOARD_UID_IN_URL.search(alert.get("dashboardURL") or "")
        dashboard_uid = match.group(1) if match else ""

    return {
        "incident_id": f"{alertname}-{fingerprint[:12]}-{epoch(started)}",
        "title": alertname,
        "alertname": alertname,
        "severity": labels.get("severity", "warning"),
        "state": "firing",
        "summary": annotations.get("summary", ""),
        "description": annotations.get("description", ""),
        "value": first_value(alert.get("values")),
        "threshold": annotations.get("threshold", ""),
        "service": labels.get("service", labels.get("service_name", "")),
        "container": labels.get("container", ""),
        "environment": labels.get("environment", ""),
        "namespace": labels.get("namespace", ""),
        "started_at": started,
        "permalink": alert.get("panelURL") or alert.get("generatorURL", ""),
        "dashboard_uid": dashboard_uid,
        "kube_context": labels.get("kube_context", KUBE_CONTEXT),
        "fingerprint": fingerprint,
        "source": "grafana",
    }


def already_forwarded(key: str) -> bool:
    now = time.time()
    with _seen_lock:
        for stale in [k for k, t in _seen.items() if now - t > DEDUP_SECONDS]:
            del _seen[stale]
        return key in _seen


def remember(key: str) -> None:
    with _seen_lock:
        _seen[key] = time.time()


def forget(key: str) -> None:
    with _seen_lock:
        _seen.pop(key, None)


def ingest(payload: dict) -> tuple[bool, str]:
    request = urllib.request.Request(
        INGEST_URL,
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {INGEST_TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "sre-example-bridge/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return True, f"HTTP {response.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code} {e.read()[:200]!r}"
    except OSError as e:
        return False, str(e)


def handle_notification(body: dict) -> dict:
    common_labels = body.get("commonLabels") or {}
    results = {"forwarded": 0, "skipped": 0, "failed": 0}
    for alert in body.get("alerts") or []:
        alertname = (alert.get("labels") or {}).get("alertname", "?")
        if alert.get("status") != "firing":
            log.info("resolved %s; nothing to triage", alertname)
            results["skipped"] += 1
            continue
        if (alert.get("annotations") or {}).get("grafana_state_reason") == "Error":
            log.warning("skip %s: it fired because its query errored", alertname)
            results["skipped"] += 1
            continue

        payload = flatten(alert, common_labels)
        key = f"{payload['fingerprint']}:{payload['started_at']}"
        if already_forwarded(key):
            log.info("skip %s: duplicate notification for %s", alertname, payload["incident_id"])
            results["skipped"] += 1
            continue

        remember(key)
        ok, detail = ingest(payload)
        if ok:
            log.info("forwarded %s as %s (%s)", alertname, payload["incident_id"], detail)
            results["forwarded"] += 1
        else:
            # Forget the key so Grafana's retry is not suppressed as a duplicate.
            forget(key)
            log.error("ingest failed for %s: %s", payload["incident_id"], detail)
            results["failed"] += 1
    return results


class Handler(BaseHTTPRequestHandler):
    server_version = "sre-example-bridge"

    def _reply(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/grafana":
            self._reply(404, {"error": "not found"})
            return
        supplied = self.headers.get("Authorization", "")
        if not BRIDGE_TOKEN or not hmac.compare_digest(supplied, f"Bearer {BRIDGE_TOKEN}"):
            self._reply(401, {"error": "bad or missing bearer token"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(413, {"error": "empty or oversized body"})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            self._reply(400, {"error": "body is not JSON"})
            return
        results = handle_notification(body)
        # A failed ingest returns 502 so Grafana retries the notification.
        self._reply(502 if results["failed"] else 200, results)

    def log_message(self, fmt: str, *args) -> None:
        log.debug(fmt, *args)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s bridge %(message)s", stream=sys.stdout)
    if not BRIDGE_TOKEN:
        log.warning("BRIDGE_TOKEN is empty; every webhook will be rejected")
    if not INGEST_TOKEN:
        log.warning("BOBI_INGEST_TOKEN is empty; the event server will reject every alert")
    log.info("listening on :%d, forwarding firing alerts to %s", LISTEN_PORT, INGEST_URL)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
