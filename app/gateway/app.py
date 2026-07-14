import os
import time
import logging
import threading
from flask import Flask, jsonify, request
import requests

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("gateway")

app = Flask(__name__)

SERVICO_URL = os.getenv("SERVICO_URL", "http://localhost:5001")
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "2"))
MAX_RETRIES = int(os.getenv("MAX_RETRIES", "3"))
CIRCUIT_BREAKER_THRESHOLD = int(os.getenv("CIRCUIT_BREAKER_THRESHOLD", "3"))
CIRCUIT_BREAKER_RECOVERY = int(os.getenv("CIRCUIT_BREAKER_RECOVERY", "10"))

class CircuitBreaker:
    def __init__(self, threshold, recovery_timeout):
        self.threshold = threshold
        self.recovery_timeout = recovery_timeout
        self.failure_count = 0
        self.last_failure_time = 0
        self.state = "CLOSED"
        self.lock = threading.Lock()

    def call(self, func, *args, **kwargs):
        with self.lock:
            if self.state == "OPEN":
                if time.time() - self.last_failure_time >= self.recovery_timeout:
                    logger.info("Circuit breaker: HALF_OPEN")
                    self.state = "HALF_OPEN"
                else:
                    raise Exception("Circuit breaker is OPEN")

        try:
            result = func(*args, **kwargs)
            with self.lock:
                if self.state == "HALF_OPEN":
                    logger.info("Circuit breaker: CLOSED (recovered)")
                    self.state = "CLOSED"
                    self.failure_count = 0
            return result
        except Exception as e:
            with self.lock:
                self.failure_count += 1
                self.last_failure_time = time.time()
                if self.failure_count >= self.threshold:
                    logger.warning(f"Circuit breaker: OPEN (failures={self.failure_count})")
                    self.state = "OPEN"
            raise e

cb = CircuitBreaker(CIRCUIT_BREAKER_THRESHOLD, CIRCUIT_BREAKER_RECOVERY)

def call_servico():
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            logger.info(f"Calling servico (attempt {attempt}/{MAX_RETRIES})")
            resp = requests.get(f"{SERVICO_URL}/process", timeout=REQUEST_TIMEOUT)
            resp.raise_for_status()
            return resp.json()
        except requests.exceptions.Timeout:
            logger.warning(f"Timeout on attempt {attempt}/{MAX_RETRIES}")
            if attempt == MAX_RETRIES:
                raise
        except requests.exceptions.RequestException as e:
            logger.warning(f"Request failed on attempt {attempt}/{MAX_RETRIES}: {e}")
            if attempt == MAX_RETRIES:
                raise
        time.sleep(0.5 * attempt)

@app.route("/api/data", methods=["GET"])
def get_data():
    try:
        data = cb.call(call_servico)
        return jsonify({"status": "ok", "data": data, "from": "gateway"})
    except Exception as e:
        logger.error(f"Fallback triggered: {e}")
        return jsonify({
            "status": "degraded",
            "data": {"message": "Servico indisponivel no momento, cache expirado"},
            "from": "gateway-fallback"
        }), 200

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
