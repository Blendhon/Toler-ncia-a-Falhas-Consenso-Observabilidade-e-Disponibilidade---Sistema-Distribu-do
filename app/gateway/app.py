import os
import sys
import time
import logging
import threading
from flask import Flask, jsonify, request
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
)
import requests
import redis

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("gateway")

app = Flask(__name__)

SERVICO_URL = os.getenv("SERVICO_URL", "http://localhost:5001")
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "2"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
CIRCUIT_BREAKER_THRESHOLD = int(os.getenv("CIRCUIT_BREAKER_THRESHOLD", "3"))
CIRCUIT_BREAKER_RECOVERY = int(os.getenv("CIRCUIT_BREAKER_RECOVERY", "10"))
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

# ── Prometheus Metrics ──
REQUEST_COUNT = Counter(
    "gateway_requests_total",
    "Total de requisicoes recebidas pelo gateway",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "gateway_request_duration_seconds",
    "Latencia das requisicoes no gateway",
    ["method", "endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0]
)
FORWARD_COUNT = Counter(
    "gateway_forward_requests_total",
    "Total de requisicoes encaminhadas ao servico",
    ["status"]
)
FORWARD_LATENCY = Histogram(
    "gateway_forward_duration_seconds",
    "Latencia das requisicoes encaminhadas ao servico",
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0]
)
RETRY_COUNT = Counter(
    "gateway_retries_total",
    "Total de retentativas realizadas pelo gateway",
    ["attempt", "result"]
)
CIRCUIT_STATE = Gauge(
    "gateway_circuit_breaker_state",
    "Estado do circuit breaker (0=closed, 1=open, 2=half_open)",
)
CIRCUIT_FAILURES = Gauge(
    "gateway_circuit_breaker_failures",
    "Numero consecutivo de falhas do circuit breaker"
)
ERROR_COUNT = Counter(
    "gateway_errors_total",
    "Total de erros no gateway",
    ["type"]
)

# ── Redis (lazy init with retry) ──
_redis_client = None
_redis_failed = False

def get_redis():
    global _redis_client, _redis_failed
    if _redis_client is not None:
        return _redis_client
    if _redis_failed:
        return None
    for attempt in range(1, 4):
        try:
            _redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True, socket_connect_timeout=2)
            _redis_client.ping()
            logger.info(f"Connected to Redis for shared state (attempt {attempt})")
            return _redis_client
        except redis.RedisError:
            logger.warning(f"Redis connection attempt {attempt}/3 failed")
            if attempt < 3:
                time.sleep(2)
    _redis_failed = True
    logger.warning("Redis unavailable after 3 attempts, toggles will be local only")
    return None

def get_toggle(key, default=True):
    r = get_redis()
    if r is None:
        return default
    try:
        val = r.get(f"gateway:toggle:{key}")
        if val is None:
            r.set(f"gateway:toggle:{key}", "1" if default else "0")
            return default
        return val == "1"
    except redis.RedisError:
        return default

def set_toggle(key, value):
    r = get_redis()
    if r is None:
        return
    try:
        r.set(f"gateway:toggle:{key}", "1" if value else "0")
    except redis.RedisError:
        pass

class CircuitBreaker:
    def __init__(self, threshold, recovery_timeout):
        self.threshold = threshold
        self.recovery_timeout = recovery_timeout
        self.failure_count = 0
        self.last_failure_time = 0
        self.state = "CLOSED"
        self.lock = threading.Lock()

    def _update_metrics(self):
        state_map = {"CLOSED": 0, "OPEN": 1, "HALF_OPEN": 2}
        CIRCUIT_STATE.set(state_map.get(self.state, 0))
        CIRCUIT_FAILURES.set(self.failure_count)

    def call(self, func, *args, **kwargs):
        if not get_toggle("cb"):
            return func(*args, **kwargs)

        with self.lock:
            if self.state == "OPEN":
                if time.time() - self.last_failure_time >= self.recovery_timeout:
                    logger.info("Circuit breaker: HALF_OPEN")
                    self.state = "HALF_OPEN"
                else:
                    raise Exception("Circuit breaker is OPEN")
            self._update_metrics()

        try:
            result = func(*args, **kwargs)
            with self.lock:
                if self.state == "HALF_OPEN":
                    logger.info("Circuit breaker: CLOSED (recovered)")
                    self.state = "CLOSED"
                    self.failure_count = 0
                self._update_metrics()
            return result
        except Exception as e:
            with self.lock:
                self.failure_count += 1
                self.last_failure_time = time.time()
                if self.failure_count >= self.threshold:
                    logger.warning(f"Circuit breaker: OPEN (failures={self.failure_count})")
                    self.state = "OPEN"
                self._update_metrics()
            raise e

cb = CircuitBreaker(CIRCUIT_BREAKER_THRESHOLD, CIRCUIT_BREAKER_RECOVERY)

def call_servico():
    retry_enabled = get_toggle("retry")
    timeout_enabled = get_toggle("timeout")
    attempts = MAX_RETRIES if retry_enabled else 1
    timeout = REQUEST_TIMEOUT if timeout_enabled else None

    for attempt in range(1, attempts + 1):
        try:
            logger.info(f"Calling servico (attempt {attempt}/{attempts}, timeout={timeout}s)")
            start = time.time()
            resp = requests.get(f"{SERVICO_URL}/process", timeout=timeout)
            elapsed = time.time() - start
            FORWARD_LATENCY.observe(elapsed)
            resp.raise_for_status()
            FORWARD_COUNT.labels(status="success").inc()
            return resp.json()
        except requests.exceptions.Timeout as e:
            logger.warning(f"Timeout on attempt {attempt}/{attempts}")
            FORWARD_COUNT.labels(status="timeout").inc()
            RETRY_COUNT.labels(attempt=str(attempt), result="timeout").inc()
            ERROR_COUNT.labels(type="timeout").inc()
            if attempt == attempts:
                raise
        except requests.exceptions.RequestException as e:
            logger.warning(f"Request failed on attempt {attempt}/{attempts}: {e}")
            FORWARD_COUNT.labels(status="error").inc()
            RETRY_COUNT.labels(attempt=str(attempt), result="error").inc()
            ERROR_COUNT.labels(type="request_error").inc()
            if attempt == attempts:
                raise
        time.sleep(0.5 * attempt)

@app.before_request
def _start_timer():
    request._prom_start = time.time()

@app.after_request
def _record_metrics(response):
    elapsed = time.time() - getattr(request, "_prom_start", time.time())
    endpoint = request.path
    method = request.method
    REQUEST_LATENCY.labels(method=method, endpoint=endpoint).observe(elapsed)
    REQUEST_COUNT.labels(method=method, endpoint=endpoint, status=response.status_code).inc()
    return response

@app.route("/api/data", methods=["GET"])
def get_data():
    try:
        data = cb.call(call_servico)
        return jsonify({"status": "ok", "data": data, "from": "gateway"})
    except Exception as e:
        logger.error(f"Fallback triggered: {e}")
        ERROR_COUNT.labels(type="fallback").inc()
        return jsonify({
            "status": "degraded",
            "data": {"message": "Servico indisponivel no momento, cache expirado"},
            "from": "gateway-fallback"
        }), 200

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})

@app.route("/metrics", methods=["GET"])
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

@app.route("/admin/status", methods=["GET"])
def admin_status():
    return jsonify({
        "circuit_breaker": get_toggle("cb"),
        "retry": get_toggle("retry"),
        "timeout": get_toggle("timeout"),
        "cb_state": cb.state if get_toggle("cb") else "BYPASSED"
    })

@app.route("/admin/toggle", methods=["POST"])
def admin_toggle():
    cb_param = request.args.get("cb")
    retry_param = request.args.get("retry")
    timeout_param = request.args.get("timeout")

    if cb_param is not None:
        set_toggle("cb", cb_param.lower() == "true")
    if retry_param is not None:
        set_toggle("retry", retry_param.lower() == "true")
    if timeout_param is not None:
        set_toggle("timeout", timeout_param.lower() == "true")

    if not get_toggle("cb"):
        with cb.lock:
            cb.state = "CLOSED"
            cb.failure_count = 0
            cb._update_metrics()

    cb_val = get_toggle("cb")
    retry_val = get_toggle("retry")
    timeout_val = get_toggle("timeout")
    logger.info(f"Toggles -> CB={cb_val}, Retry={retry_val}, Timeout={timeout_val}")

    return jsonify({
        "circuit_breaker": cb_val,
        "retry": retry_val,
        "timeout": timeout_val
    })

@app.route("/admin/flush", methods=["POST"])
def admin_flush():
    try:
        resp = requests.post(f"{SERVICO_URL}/process/flush", timeout=5)
        return jsonify(resp.json())
    except Exception as e:
        return jsonify({"flushed": False, "error": str(e)}), 502

@app.route("/admin/slow", methods=["POST"])
def admin_slow():
    try:
        qs = request.query_string.decode()
        resp = requests.post(f"{SERVICO_URL}/admin/slow?{qs}", timeout=5)
        return jsonify(resp.json())
    except Exception as e:
        return jsonify({"error": str(e)}), 502

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
