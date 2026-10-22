"""A deliberately small alert evaluator: Prometheus rules without Prometheus.

It scrapes one /metrics endpoint, evaluates the rules in rules.json, and POSTs
each newly firing alert to the bobi event server's ingest webhook:

    POST {BOBI_INGEST_URL}            (…/webhooks/ingest/alert/firing)
    Authorization: Bearer {BOBI_INGEST_TOKEN}

The payload is flat on purpose. bobi copies only top-level string/number/bool
fields into the event's `fields`, and the triage workflow reads its
`${{input.*}}` variables from there; nested objects never reach the workflow.

Standard library only, so it runs in a bare python image.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("alerter")

METRICS_URL = os.environ.get("APP_METRICS_URL", "http://localhost:8000/metrics")
INGEST_URL = os.environ.get("BOBI_INGEST_URL", "http://localhost:8080/webhooks/ingest/alert/firing")
INGEST_TOKEN = os.environ.get("BOBI_INGEST_TOKEN", "")
RULES_FILE = Path(os.environ.get("ALERTER_RULES", Path(__file__).with_name("rules.json")))
INTERVAL = float(os.environ.get("ALERTER_INTERVAL_SECONDS", "10"))
ENVIRONMENT = os.environ.get("ALERT_ENVIRONMENT", "local")
NAMESPACE = os.environ.get("ALERT_NAMESPACE", "docker-compose")
SERVICE = os.environ.get("ALERT_SERVICE", "flux-capacitor")
CONTAINER = os.environ.get("ALERT_CONTAINER", "sre-example-app")
PERMALINK = os.environ.get("ALERT_PERMALINK", "http://localhost:8000/chaos")


def parse_metrics(text: str) -> dict[str, list[tuple[dict[str, str], float]]]:
    """Parse the Prometheus text exposition format into {name: [(labels, value)]}."""
    samples: dict[str, list[tuple[dict[str, str], float]]] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name_part, _, value_part = line.rpartition(" ")
        try:
            value = float(value_part)
        except ValueError:
            continue
        labels: dict[str, str] = {}
        if "{" in name_part:
            name, _, raw = name_part.partition("{")
            for pair in raw.rstrip("}").split('",'):
                if "=" in pair:
                    key, _, val = pair.partition("=")
                    labels[key.strip()] = val.strip().strip('"')
        else:
            name = name_part
        samples.setdefault(name, []).append((labels, value))
    return samples


def total(samples: dict, name: str, match=lambda labels: True) -> float:
    return sum(v for labels, v in samples.get(name, []) if match(labels))


@dataclass
class History:
    """Recent scrapes, so counter rules can compute rates over a window."""

    points: list[tuple[float, dict]] = field(default_factory=list)

    def add(self, now: float, samples: dict) -> None:
        self.points.append((now, samples))
        horizon = now - 600
        self.points = [(t, s) for t, s in self.points if t >= horizon]

    def oldest_within(self, now: float, window: float) -> tuple[float, dict] | None:
        for t, s in self.points:
            if now - t <= window:
                return t, s
        return None


def evaluate(rule: dict, samples: dict | None, history: History, now: float) -> float | None:
    """Return the rule's current value, or None when it cannot be computed."""
    kind = rule["kind"]
    if kind == "target_down":
        return 1.0 if samples is None else 0.0
    if samples is None:
        return None
    if kind == "gauge":
        values = [v for _, v in samples.get(rule["metric"], [])]
        return max(values) if values else None
    past = history.oldest_within(now, rule.get("window_seconds", 60))
    if past is None or past[0] == now:
        return None
    _, old = past
    if kind == "error_ratio":
        is_5xx = lambda labels: labels.get("status", "").startswith("5")
        errors = total(samples, "http_requests_total", is_5xx) - total(old, "http_requests_total", is_5xx)
        requests = total(samples, "http_requests_total") - total(old, "http_requests_total")
        return errors / requests if requests > 0 else 0.0
    if kind == "avg_latency":
        seconds = total(samples, "http_request_duration_seconds_sum") - total(old, "http_request_duration_seconds_sum")
        count = total(samples, "http_request_duration_seconds_count") - total(old, "http_request_duration_seconds_count")
        return seconds / count if count > 0 else 0.0
    raise ValueError(f"unknown rule kind {kind!r}")


@dataclass
class RuleState:
    pending_since: float | None = None
    firing_since: float | None = None
    incident_id: str | None = None


def alert_payload(rule: dict, value: float, started: float) -> dict:
    """The flat alert record the triage workflow consumes as ${{input.*}}."""
    incident_id = f"{rule['name']}-{int(started)}"
    return {
        "incident_id": incident_id,
        "title": rule["name"],
        "alertname": rule["name"],
        "severity": rule["severity"],
        "state": "firing",
        "summary": rule["summary"],
        "description": rule.get("description", ""),
        "value": round(value, 4),
        "threshold": rule["threshold"],
        "service": SERVICE,
        "container": CONTAINER,
        "environment": ENVIRONMENT,
        "namespace": NAMESPACE,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "permalink": PERMALINK,
        "dashboard_uid": "",
        "kube_context": "",
        "source": "alerter",
    }


def post_alert(payload: dict) -> bool:
    request = urllib.request.Request(
        INGEST_URL,
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {INGEST_TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "sre-example-alerter/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            log.info("alert %s delivered (HTTP %d)", payload["incident_id"], response.status)
            return True
    except urllib.error.HTTPError as e:
        log.error("ingest rejected %s: HTTP %d %s", payload["incident_id"], e.code, e.read()[:200])
    except OSError as e:
        log.error("ingest unreachable for %s: %s", payload["incident_id"], e)
    return False


def scrape() -> dict | None:
    try:
        with urllib.request.urlopen(METRICS_URL, timeout=5) as response:
            return parse_metrics(response.read().decode())
    except OSError as e:
        log.warning("scrape of %s failed: %s", METRICS_URL, e)
        return None


def run() -> None:
    rules = json.loads(RULES_FILE.read_text())["rules"]
    states = {rule["name"]: RuleState() for rule in rules}
    history = History()
    log.info("watching %s with %d rules; alerts go to %s", METRICS_URL, len(rules), INGEST_URL)
    if not INGEST_TOKEN:
        log.warning("BOBI_INGEST_TOKEN is empty; the event server will reject every alert")

    while True:
        now = time.time()
        samples = scrape()
        if samples is not None:
            history.add(now, samples)
        for rule in rules:
            state = states[rule["name"]]
            value = evaluate(rule, samples, history, now)
            breaching = value is not None and value > rule["threshold"]
            if not breaching:
                if state.firing_since is not None:
                    log.info("RESOLVED %s (incident %s)", rule["name"], state.incident_id)
                states[rule["name"]] = RuleState()
                continue
            if state.pending_since is None:
                state.pending_since = now
                log.info("PENDING %s value=%.4f threshold=%s", rule["name"], value, rule["threshold"])
            if state.firing_since is None and now - state.pending_since >= rule.get("for_seconds", 30):
                payload = alert_payload(rule, value, state.pending_since)
                log.warning("FIRING %s value=%.4f threshold=%s", rule["name"], value, rule["threshold"])
                if post_alert(payload):
                    state.firing_since = now
                    state.incident_id = payload["incident_id"]
        time.sleep(INTERVAL)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s alerter %(message)s", stream=sys.stdout)
    run()
