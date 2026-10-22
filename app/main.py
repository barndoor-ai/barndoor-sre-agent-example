"""Flux Capacitor service: a tiny web app that exists to break on demand.

It serves traffic, exports Prometheus metrics, and has chaos endpoints that
inject the failures the SRE agent is meant to triage:

    POST /chaos/overload   push flux_capacitor_gigawatts above the 1.21 GW limit
    POST /chaos/errors     make a share of requests fail with HTTP 500
    POST /chaos/latency    slow every request down
    POST /chaos/crash      exit the process (the orchestrator restarts it)
    POST /chaos/reset      clear every fault

Each fault logs what it is doing, so an investigator reading container logs can
reconstruct the timeline.
"""

from __future__ import annotations

import logging
import os
import random
import threading
import time
import urllib.request

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

SERVICE = os.environ.get("SERVICE_NAME", "flux-capacitor")
PORT = int(os.environ.get("PORT", "8000"))
LOAD_RPS = float(os.environ.get("LOAD_RPS", "5"))
SAFE_GIGAWATTS = 1.21
NOMINAL_GIGAWATTS = 1.0
OVERLOAD_GIGAWATTS = 2.4

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s " + SERVICE + " %(message)s",
)
log = logging.getLogger(SERVICE)

REQUESTS = Counter(
    "http_requests_total", "HTTP requests served", ["method", "path", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "path"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
GIGAWATTS = Gauge("flux_capacitor_gigawatts", "Current flux capacitor output in gigawatts")


class Chaos:
    """Process-wide fault state. One lock; faults are independent."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.overload = False
        self.error_rate = 0.0
        self.latency_seconds = 0.0

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "overload": self.overload,
                "error_rate": self.error_rate,
                "latency_seconds": self.latency_seconds,
            }


chaos = Chaos()
app = FastAPI(title="Flux Capacitor")


def _drive_gauge() -> None:
    """Move the gauge toward its target so it looks like a real signal."""
    value = NOMINAL_GIGAWATTS
    while True:
        target = OVERLOAD_GIGAWATTS if chaos.snapshot()["overload"] else NOMINAL_GIGAWATTS
        value += (target - value) * 0.3 + random.uniform(-0.02, 0.02)
        GIGAWATTS.set(round(value, 3))
        if value > SAFE_GIGAWATTS:
            log.warning(
                "flux capacitor output %.2f GW exceeds the %.2f GW safety limit",
                value,
                SAFE_GIGAWATTS,
            )
        time.sleep(5)


def _generate_load() -> None:
    """Send steady self-traffic so request metrics move without extra tooling."""
    if LOAD_RPS <= 0:
        return
    time.sleep(3)
    url = f"http://127.0.0.1:{PORT}/"
    while True:
        try:
            urllib.request.urlopen(url, timeout=10).read()
        except Exception:
            pass
        time.sleep(1.0 / LOAD_RPS)


@app.on_event("startup")
def _start_background_threads() -> None:
    GIGAWATTS.set(NOMINAL_GIGAWATTS)
    threading.Thread(target=_drive_gauge, daemon=True, name="gauge").start()
    threading.Thread(target=_generate_load, daemon=True, name="load").start()
    log.info("time circuits on: serving on port %d (self-load %.1f rps)", PORT, LOAD_RPS)


@app.middleware("http")
async def _instrument(request: Request, call_next):
    path = request.url.path
    if path == "/metrics":
        return await call_next(request)
    started = time.perf_counter()
    response = await call_next(request)
    LATENCY.labels(request.method, path).observe(time.perf_counter() - started)
    REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    return response


@app.get("/")
def index() -> Response:
    faults = chaos.snapshot()
    if faults["latency_seconds"]:
        time.sleep(faults["latency_seconds"])
        log.warning("temporal displacement lag: request delayed %.0f ms", faults["latency_seconds"] * 1000)
    if faults["error_rate"] and random.random() < faults["error_rate"]:
        log.error("flux capacitor coolant pressure low: failing request with HTTP 500")
        return JSONResponse({"error": "coolant pressure low"}, status_code=500)
    return JSONResponse({"service": SERVICE, "status": "time circuits on"})


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/chaos")
def chaos_state() -> dict:
    return chaos.snapshot()


@app.post("/chaos/overload")
def chaos_overload(request: Request) -> dict:
    with chaos.lock:
        chaos.overload = True
    log.warning("CHAOS: overload fault enabled via POST /chaos/overload from %s", _caller(request))
    return chaos.snapshot()


@app.post("/chaos/errors")
def chaos_errors(request: Request, rate: float = 0.3) -> dict:
    rate = min(max(rate, 0.0), 1.0)
    with chaos.lock:
        chaos.error_rate = rate
    log.warning(
        "CHAOS: error fault enabled via POST /chaos/errors (rate=%.2f) from %s", rate, _caller(request)
    )
    return chaos.snapshot()


@app.post("/chaos/latency")
def chaos_latency(request: Request, seconds: float = 1.5) -> dict:
    seconds = min(max(seconds, 0.0), 10.0)
    with chaos.lock:
        chaos.latency_seconds = seconds
    log.warning(
        "CHAOS: latency fault enabled via POST /chaos/latency (%.1fs) from %s", seconds, _caller(request)
    )
    return chaos.snapshot()


@app.post("/chaos/crash")
def chaos_crash(request: Request) -> dict:
    log.critical("CHAOS: crash requested via POST /chaos/crash from %s; exiting in 1s", _caller(request))

    def _exit() -> None:
        time.sleep(1)
        os._exit(1)

    threading.Thread(target=_exit, daemon=True).start()
    return {"crashing": True}


@app.post("/chaos/reset")
def chaos_reset(request: Request) -> dict:
    with chaos.lock:
        chaos.overload = False
        chaos.error_rate = 0.0
        chaos.latency_seconds = 0.0
    log.info("CHAOS: all faults cleared via POST /chaos/reset from %s", _caller(request))
    return chaos.snapshot()


def _caller(request: Request) -> str:
    return request.client.host if request.client else "unknown"


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT, access_log=False)
