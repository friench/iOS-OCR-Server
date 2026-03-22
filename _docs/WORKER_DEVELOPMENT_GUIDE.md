# OCR Worker Development Guide

This guide explains how to write an **OCR Worker** — an external service that plugs into the Thai Lawyer CRM OCR pipeline via HTTPS API.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Worker Lifecycle](#worker-lifecycle)
3. [API Reference](#api-reference)
4. [Authentication](#authentication)
5. [Python Example Worker](#python-example-worker)
6. [Error Handling & Retry Logic](#error-handling--retry-logic)
7. [Monitoring & Logging](#monitoring--logging)
8. [Deployment](#deployment)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                    Thai Lawyer CRM API                    │
│                                                          │
│  BullMQ Queue → OcrProcessor → OcrWorkerPoolService     │
│                                      │                   │
│                               SelectWorker               │
│                                      │                   │
└──────────────────────────────────────│───────────────────┘
                                       │ POST /process
                               ┌───────▼──────────┐
                               │   Your Worker    │
                               │                  │
                               │  1. Download file│
                               │  2. Run OCR      │
                               │  3. POST callback│
                               └──────────────────┘
```

**Key points:**

- Workers are **external HTTP servers** — you host them anywhere.
- The API server **pushes** jobs to workers (not a polling model).
- Workers receive a **presigned S3 download URL** — no direct S3 credentials required.
- When processing is complete, the worker **POSTs results** back to a callback URL.
- Workers must send periodic **heartbeats** so the pool manager knows they are alive.

---

## Worker Lifecycle

### 1. Startup — Register with the API

```
POST /api/v1/ocr-workers/register
```

On startup your worker registers itself. The API responds with a `workerId` and the expected `heartbeatInterval`.

### 2. Heartbeat Loop

Send a heartbeat every `heartbeatInterval` seconds (default: 60 s). Workers that miss heartbeats for more than **2 minutes** are marked **offline** and will stop receiving jobs.

### 3. Accept OCR Jobs

The API will POST jobs to `POST {your_endpoint}/process`. Your worker must have an HTTP server listening on the registered endpoint.

### 4. Download, Process, Respond

1. Download the document via the presigned URL.
2. Run OCR (tesseract, easyocr, etc.).
3. POST the result to the provided `callbackUrl`.

### 5. Graceful Shutdown

Before stopping, call the **unregister** endpoint so the pool manager doesn't wait for heartbeats.

---

## API Reference

All endpoints are at `{API_URL}/api/v1/ocr-workers`.

---

### POST `/api/v1/ocr-workers/register`

Register a new worker.

**Request body:**

```json
{
  "name": "my-ocr-worker",
  "endpoint": "https://ocr-worker.example.com",
  "capabilities": ["tesseract", "easyocr"],
  "secret": "your-shared-secret"
}
```

| Field          | Type     | Required | Description                                          |
| -------------- | -------- | -------- | ---------------------------------------------------- |
| `name`         | string   | yes      | Human-readable label for this worker instance        |
| `endpoint`     | string   | yes      | Public HTTPS URL of your worker (no localhost)       |
| `capabilities` | string[] | yes      | OCR engines supported: `tesseract`, `easyocr`, etc. |
| `secret`       | string   | no       | Shared secret (required if `OCR_WORKERS_SECRET` set) |

**Response (201):**

```json
{
  "workerId": "f4a1bc20-...",
  "heartbeatInterval": 60
}
```

Store `workerId` — you will need it for all subsequent API calls.

---

### POST `/api/v1/ocr-workers/:workerId/heartbeat`

Keep the worker registration alive.

**Request body:**

```json
{
  "status": "idle",
  "activeJobs": 0
}
```

| Field        | Type   | Values            | Description               |
| ------------ | ------ | ----------------- | ------------------------- |
| `status`     | string | `idle` \| `busy`  | Current processing state  |
| `activeJobs` | number | ≥ 0               | Number of jobs in flight  |

**Response (200):** `{ "status": "ok" }`

---

### POST `/api/v1/ocr-workers/:workerId/unregister`

Gracefully remove the worker from the pool.

**Response (200):** `{ "status": "ok" }`

---

### GET `/api/v1/ocr-workers`

List all registered workers. **Requires Bearer token (admin only).**

---

### GET `/api/v1/ocr-workers/:workerId/status`

Get status of a specific worker. **Requires Bearer token (admin only).**

---

### POST `/api/v1/ocr-workers/jobs/:jobId/complete`

Submit the OCR result back to the API (**this is the callback endpoint**).

`jobId` is the value provided in the incoming job payload.

**Request body:**

```json
{
  "workerId": "f4a1bc20-...",
  "success": true,
  "ocrResult": {
    "text": "Extracted text content here",
    "boxes": [
      { "text": "John", "x": 120, "y": 80, "w": 60, "h": 20 }
    ],
    "confidence": 94.5
  },
  "processingTimeMs": 1250
}
```

On failure:

```json
{
  "workerId": "f4a1bc20-...",
  "success": false,
  "error": "Unsupported image format"
}
```

| Field               | Type    | Required | Description                          |
| ------------------- | ------- | -------- | ------------------------------------ |
| `workerId`          | string  | yes      | Your worker's UUID                   |
| `success`           | boolean | yes      | Whether OCR succeeded                |
| `ocrResult`         | object  | no       | OCR output (required when success)   |
| `ocrResult.text`    | string  | yes*     | Full extracted text                  |
| `ocrResult.boxes`   | array   | no       | Per-word bounding boxes              |
| `ocrResult.confidence` | number | no    | Overall confidence score 0–100       |
| `error`             | string  | no       | Error message (when success=false)   |
| `processingTimeMs`  | number  | no       | Processing duration in milliseconds  |

**Response (200):** `{ "status": "ok" }`

> ⚠️ The job callback has a **5-minute timeout**. If the callback is not received within 5 minutes, the job will fail and fall back to the built-in OCR chain.

---

### Incoming Job Payload (your `/process` endpoint)

When the API dispatches an OCR job, it POSTs the following JSON to `{your_endpoint}/process`:

```json
{
  "jobId": "bull:ocr:42",
  "documentId": "d1e2f3...",
  "fileDownloadUrl": "https://s3.example.com/documents/scan.pdf?...",
  "callbackUrl": "https://api.example.com/api/v1/ocr-workers/jobs/bull:ocr:42/complete",
  "language": "en"
}
```

| Field             | Type   | Description                                         |
| ----------------- | ------ | --------------------------------------------------- |
| `jobId`           | string | BullMQ job ID — use as `:jobId` in the callback URL |
| `documentId`      | string | Database document ID (for logging)                  |
| `fileDownloadUrl` | string | Presigned URL valid for 10 minutes                  |
| `callbackUrl`     | string | Full URL to POST your results to                    |
| `language`        | string | Hint language code (optional, e.g. `th`, `en`)      |

---

## Authentication

### Shared Secret

If `OCR_WORKERS_SECRET` is set on the API server, you must include it in the registration request:

```json
{ "secret": "your-shared-secret" }
```

Registration will fail with **401 Unauthorized** if the secret is missing or wrong.

### Worker ID as Identity

After registration, your `workerId` is used to identify your worker on heartbeat, unregister, and job completion endpoints. Keep it secure — treat it like an API key.

> Workers registering with a localhost or private-network `endpoint` will be rejected to prevent SSRF attacks.

---

## Python Example Worker

Below is a complete, production-quality example using Python 3.10+.

### Dependencies

```bash
pip install requests flask pytesseract pillow
```

### worker.py

```python
#!/usr/bin/env python3
"""
Thai Lawyer CRM — OCR Worker
Connects to the CRM API, accepts OCR jobs, and returns results.
"""

import io
import logging
import os
import sys
import threading
import time

import pytesseract
import requests
from flask import Flask, Response, jsonify, request
from PIL import Image

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

API_BASE_URL = os.environ["CRM_API_URL"].rstrip("/")          # e.g. https://api.example.com
WORKER_SECRET = os.environ.get("OCR_WORKERS_SECRET", "")      # must match server config
WORKER_NAME   = os.environ.get("WORKER_NAME", "ocr-worker-1")
WORKER_PORT   = int(os.environ.get("WORKER_PORT", "8888"))
PUBLIC_URL    = os.environ["WORKER_PUBLIC_URL"].rstrip("/")    # e.g. https://ocr.example.com

REGISTER_URL     = f"{API_BASE_URL}/api/v1/ocr-workers/register"
HEARTBEAT_URL_T  = f"{API_BASE_URL}/api/v1/ocr-workers/{{worker_id}}/heartbeat"
UNREGISTER_URL_T = f"{API_BASE_URL}/api/v1/ocr-workers/{{worker_id}}/unregister"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ocr-worker")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

worker_id: str | None = None
heartbeat_interval: int = 60
active_jobs: int = 0
shutdown_event = threading.Event()

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

def register() -> None:
    """Register this worker with the CRM API."""
    global worker_id, heartbeat_interval

    payload = {
        "name": WORKER_NAME,
        "endpoint": PUBLIC_URL,
        "capabilities": ["tesseract"],
    }
    if WORKER_SECRET:
        payload["secret"] = WORKER_SECRET

    log.info(f"Registering with {REGISTER_URL} ...")
    resp = requests.post(REGISTER_URL, json=payload, timeout=30)
    resp.raise_for_status()

    data = resp.json()
    worker_id = data["workerId"]
    heartbeat_interval = data["heartbeatInterval"]

    log.info(f"Registered as worker {worker_id} (heartbeat every {heartbeat_interval}s)")


def unregister() -> None:
    """Gracefully unregister before shutdown."""
    if not worker_id:
        return
    url = UNREGISTER_URL_T.format(worker_id=worker_id)
    try:
        requests.post(url, timeout=10)
        log.info(f"Unregistered worker {worker_id}")
    except Exception as exc:
        log.warning(f"Unregister failed: {exc}")


# ---------------------------------------------------------------------------
# Heartbeat loop
# ---------------------------------------------------------------------------

def heartbeat_loop() -> None:
    """Background thread: send heartbeat every `heartbeat_interval` seconds."""
    while not shutdown_event.wait(timeout=heartbeat_interval):
        if not worker_id:
            continue
        status = "busy" if active_jobs > 0 else "idle"
        url = HEARTBEAT_URL_T.format(worker_id=worker_id)
        try:
            requests.post(url, json={"status": status, "activeJobs": active_jobs}, timeout=10)
        except Exception as exc:
            log.warning(f"Heartbeat failed: {exc}")


# ---------------------------------------------------------------------------
# OCR processing
# ---------------------------------------------------------------------------

def run_ocr(file_bytes: bytes, language: str | None = None) -> dict:
    """Run Tesseract OCR on raw file bytes and return a result dict."""
    img = Image.open(io.BytesIO(file_bytes))
    lang = language if language else "eng"

    # Full text extraction
    text = pytesseract.image_to_string(img, lang=lang)

    # Bounding boxes
    data = pytesseract.image_to_data(img, lang=lang, output_type=pytesseract.Output.DICT)
    boxes = []
    for i, word in enumerate(data["text"]):
        if word.strip():
            boxes.append({
                "text": word,
                "x": data["left"][i],
                "y": data["top"][i],
                "w": data["width"][i],
                "h": data["height"][i],
            })

    # Average confidence (filter out -1 entries from empty words)
    confidences = [c for c in data["conf"] if c != -1]
    avg_confidence = sum(confidences) / len(confidences) if confidences else 0

    return {
        "text": text.strip(),
        "boxes": boxes,
        "confidence": round(avg_confidence, 1),
    }


# ---------------------------------------------------------------------------
# Flask HTTP server (accepts OCR jobs)
# ---------------------------------------------------------------------------

app = Flask(__name__)


@app.route("/process", methods=["POST"])
def process_job():
    """Receive an OCR job from the CRM API."""
    global active_jobs

    payload = request.get_json(force=True)
    job_id        = payload["jobId"]
    document_id   = payload["documentId"]
    download_url  = payload["fileDownloadUrl"]
    callback_url  = payload["callbackUrl"]
    language      = payload.get("language")

    log.info(f"Received job {job_id} for document {document_id}")

    # Process asynchronously so we can return 200 quickly.
    def _process():
        global active_jobs
        active_jobs += 1
        start = time.time()
        try:
            # 1. Download the file.
            file_resp = requests.get(download_url, timeout=60)
            file_resp.raise_for_status()

            # 2. Run OCR.
            result = run_ocr(file_resp.content, language=language)
            elapsed_ms = int((time.time() - start) * 1000)

            # 3. POST callback with success.
            requests.post(callback_url, json={
                "workerId": worker_id,
                "success": True,
                "ocrResult": result,
                "processingTimeMs": elapsed_ms,
            }, timeout=30)

            log.info(f"Job {job_id} completed in {elapsed_ms}ms")

        except Exception as exc:
            elapsed_ms = int((time.time() - start) * 1000)
            log.error(f"Job {job_id} failed: {exc}")

            # POST callback with failure.
            try:
                requests.post(callback_url, json={
                    "workerId": worker_id,
                    "success": False,
                    "error": str(exc),
                    "processingTimeMs": elapsed_ms,
                }, timeout=30)
            except Exception as cb_exc:
                log.error(f"Callback POST also failed: {cb_exc}")

        finally:
            active_jobs = max(0, active_jobs - 1)

    threading.Thread(target=_process, daemon=True).start()

    return jsonify({"status": "accepted"}), 202


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "workerId": worker_id, "activeJobs": active_jobs})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    register()

    # Start heartbeat thread.
    hb_thread = threading.Thread(target=heartbeat_loop, daemon=True)
    hb_thread.start()

    try:
        # Start Flask (use gunicorn / uvicorn in production).
        app.run(host="0.0.0.0", port=WORKER_PORT, threaded=True)
    except KeyboardInterrupt:
        log.info("Shutting down ...")
    finally:
        shutdown_event.set()
        unregister()
```

### Running the worker

```bash
export CRM_API_URL=https://api.yourdomain.com
export WORKER_PUBLIC_URL=https://ocr-worker.yourdomain.com
export OCR_WORKERS_SECRET=your-secret-key-here

python worker.py
```

---

## Error Handling & Retry Logic

### Network errors when posting the callback

Always wrap the callback POST in a try/except. Even if the callback fails, include it in your logging so you can debug issues.

```python
for attempt in range(3):
    try:
        resp = requests.post(callback_url, json=result, timeout=30)
        resp.raise_for_status()
        break
    except Exception as exc:
        log.warning(f"Callback attempt {attempt + 1} failed: {exc}")
        time.sleep(2 ** attempt)  # exponential back-off
```

### Job timeout

The API waits **5 minutes** for a callback. If your job takes longer, it will time out and the CRM will fall back to its built-in OCR chain. Design your worker to complete well within this limit.

### Worker crash recovery

If your worker crashes between accepting a job and sending the callback, the job will time out on the API side. Consider:

1. Persisting accepted jobs to disk/database before processing.
2. On restart, check for any unfinished jobs and attempt to resume or report failure.

---

## Monitoring & Logging

### Structured logging

Log every job event with structured fields:

```python
log.info("job_start", extra={"job_id": job_id, "document_id": document_id})
log.info("job_complete", extra={"job_id": job_id, "elapsed_ms": elapsed_ms, "confidence": confidence})
log.error("job_failed", extra={"job_id": job_id, "error": str(exc)})
```

### Metrics to track

| Metric                      | How to measure                        |
| --------------------------- | ------------------------------------- |
| Jobs processed per minute   | Counter incremented in `_process()`   |
| Average OCR processing time | Track `elapsed_ms` per job            |
| Average confidence score    | Log `confidence` from Tesseract       |
| Heartbeat success rate      | Track heartbeat HTTP response codes   |
| Active job count            | `active_jobs` global variable         |

### Health endpoint

Expose a `/health` endpoint (shown in the example above). You can use it as the health check for container orchestrators.

---

## Deployment

### Docker

```dockerfile
FROM python:3.11-slim

RUN apt-get update && apt-get install -y tesseract-ocr tesseract-ocr-tha \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py .

ENV WORKER_PORT=8888
EXPOSE 8888

CMD ["python", "worker.py"]
```

```yaml
# docker-compose.yml
services:
  ocr-worker:
    build: .
    environment:
      CRM_API_URL: https://api.yourdomain.com
      WORKER_PUBLIC_URL: https://ocr-worker.yourdomain.com
      OCR_WORKERS_SECRET: ${OCR_WORKERS_SECRET}
      WORKER_NAME: ocr-worker-1
    ports:
      - "8888:8888"
    restart: unless-stopped
```

### Production recommendations

1. **Use gunicorn** (or uvicorn) instead of Flask's built-in server:
   ```bash
   gunicorn -w 4 -b 0.0.0.0:8888 worker:app
   ```

2. **TLS termination** — put an Nginx or Caddy reverse proxy in front to handle HTTPS. The `WORKER_PUBLIC_URL` must be `https://`.

3. **Scale horizontally** — register multiple worker instances. The pool manager uses round-robin selection, preferring idle workers.

4. **Thai language support** — install the Tesseract Thai language pack:
   ```bash
   apt-get install tesseract-ocr-tha
   # Then use lang="tha" in pytesseract.image_to_string(...)
   ```

5. **Keep the worker endpoint publicly reachable** — the CRM API needs to be able to POST to it. Localhost and private-network addresses are rejected at registration.
