# OCR Worker Development Guide

This guide explains how to build an **OCR Worker** that integrates with the iOS OCR Server. Two connection models are supported:

- **SSE (Server-Sent Events)** — the worker opens a long-lived outbound connection and receives jobs as events. **Recommended for workers behind NAT/mobile networks.**
- **Push** — the API server sends jobs directly to the worker's HTTP endpoint. Requires the worker to be reachable from the server.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Worker Lifecycle](#worker-lifecycle)
3. [API Reference](#api-reference)
4. [iOS OCR Server as a Worker](#ios-ocr-server-as-a-worker)
5. [Building a Custom Worker (Python Examples)](#building-a-custom-worker-python-examples)
6. [Error Handling & Retry](#error-handling--retry)
7. [Security](#security)
8. [Best Practices](#best-practices)

---

## Architecture Overview

### SSE Model (Recommended)

```
┌─────────────────┐                              ┌───────────────────┐
│   API Server    │                               │   OCR Worker      │
│   (coordinator) │                               │  (iOS / Python)   │
│                 │ ◀── SSE connect ─────────────│                   │
│                 │ ── event: job ──────────────▶ │                   │
│                 │ ◀── POST callback ───────────│                   │
└────────┬────────┘                               └───────┬───────────┘
         │                                                 │
         │  register / unregister                          │
         │ ◀───────────────────────────────────────────────┘
```

**SSE model** — the worker opens a long-lived SSE connection to the server and receives OCR jobs as server-sent events. All connections are outbound from the worker, making it **NAT-friendly** with no public endpoint required. The SSE connection itself proves liveness — **no heartbeat needed**.

### Push Model

```
┌─────────────────┐          push job            ┌───────────────────┐
│   API Server    │ ──────────────────────────▶  │   OCR Worker      │
│   (coordinator) │  POST /process               │  (iOS / Python)   │
│                 │ ◀──────────────────────────  │                   │
│                 │   POST callback with result  │                   │
└────────┬────────┘                              └───────┬───────────┘
         │                                               │
         │  register / heartbeat / unregister             │
         │ ◀─────────────────────────────────────────────┘
```

**Push model** — the API server pushes OCR jobs directly to the worker's HTTP endpoint. Workers must be reachable by the server and send periodic heartbeats.

### Key Concepts

| Term | Description |
|------|-------------|
| **API Server** | Central coordinator that manages the job queue and dispatches work to registered workers |
| **Worker** | A service that receives OCR jobs, processes images/PDFs, and returns results via callback |
| **SSE Stream** | A `GET` connection from worker to server that receives job events in real time |
| **Endpoint** | (Push only) The worker's HTTP URL where it accepts `POST /process` requests |
| **Callback URL** | A URL provided per-job where the worker POSTs the OCR result |
| **Heartbeat** | (Push only) Periodic signal from worker to API server confirming it's alive |

### Model Comparison

| Feature | SSE | Push |
|---------|-----|------|
| NAT-friendly | Yes — all outbound | No — requires inbound access |
| Public endpoint | Not needed | Required |
| Heartbeat | Not needed (connection = liveness) | Required |
| Latency | Low (real-time events) | Low (direct HTTP push) |
| Scalability | One SSE connection per worker | One POST per job |
| Mobile-friendly | Yes | No |

---

## Worker Lifecycle

### SSE Lifecycle

```
1. REGISTER    →  POST /api/v1/ocr-workers/register
                  Worker sends: name, capabilities, secret, mode="sse"
                  Server returns: workerId

2. SSE CONNECT →  GET /api/v1/ocr-workers/:workerId/events
                  Headers: Accept: text/event-stream
                           Authorization: Bearer <secret>
                           Last-Event-ID: <optional>
                  Long-lived connection — stays open

3. RECEIVE JOB →  Server sends SSE event:
                  event: job
                  data: {"jobId":"...","fileDownloadUrl":"...","callbackUrl":"..."}

4. PROCESS     →  Worker downloads the file, runs OCR

5. CALLBACK    →  POST <callbackUrl>
                  Worker sends: workerId, success, ocrResult, processingTimeMs

6. RECONNECT   →  On connection drop: reconnect with exponential backoff
                  Send Last-Event-ID to resume from last received event

7. UNREGISTER  →  POST /api/v1/ocr-workers/:workerId/unregister
                  Called on graceful shutdown
```

### Push Lifecycle

```
1. REGISTER    →  POST /api/v1/ocr-workers/register
                  Worker sends: name, endpoint, capabilities, secret, mode="push"
                  Server returns: workerId, heartbeatInterval

2. HEARTBEAT   →  POST /api/v1/ocr-workers/:workerId/heartbeat
                  Worker sends: status, activeJobs
                  Runs in a loop at the server-specified interval

3. RECEIVE JOB →  The API server POSTs to worker's endpoint:
                  POST <workerEndpoint>/process
                  Payload: jobId, fileDownloadUrl, callbackUrl, language

4. PROCESS     →  Worker downloads the file, runs OCR

5. CALLBACK    →  POST <callbackUrl>
                  Worker sends: workerId, success, ocrResult, processingTimeMs

6. UNREGISTER  →  POST /api/v1/ocr-workers/:workerId/unregister
                  Called on graceful shutdown
```

---

## API Reference

### 1. Register Worker

```
POST /api/v1/ocr-workers/register
Content-Type: application/json
```

**Request body (SSE mode):**

```json
{
  "name": "ocr-worker-ios",
  "capabilities": ["apple-vision"],
  "secret": "shared-secret-string",
  "mode": "sse"
}
```

**Request body (Push mode):**

```json
{
  "name": "ocr-worker-ios",
  "endpoint": "http://192.168.1.100:8000",
  "capabilities": ["apple-vision"],
  "secret": "shared-secret-string",
  "mode": "push"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable worker identifier |
| `mode` | string | yes | `"sse"` or `"push"` — determines connection model |
| `endpoint` | string | push only | Base URL where the worker listens for jobs (not needed for SSE) |
| `capabilities` | string[] | yes | OCR engines the worker supports (e.g. `apple-vision`, `tesseract`) |
| `secret` | string | no | Shared secret for authentication |

**Response (200/201):**

SSE mode:
```json
{
  "workerId": "w-abc123"
}
```

Push mode:
```json
{
  "workerId": "w-abc123",
  "heartbeatInterval": 60
}
```

| Field | Type | Description |
|-------|------|-------------|
| `workerId` | string | Unique identifier assigned by the server |
| `heartbeatInterval` | int | (Push only) Seconds between heartbeats |

**Error responses:**

| Status | Meaning |
|--------|---------|
| 401/403 | Authentication failed — check secret |
| 400 | Invalid registration payload |

---

### 2. SSE Events Stream

Available only for workers registered with `mode: "sse"`.

```
GET /api/v1/ocr-workers/:workerId/events
Accept: text/event-stream
Cache-Control: no-cache
Authorization: Bearer <secret>
Last-Event-ID: <optional — resume from last event>
```

The server responds with a **200** status and `Content-Type: text/event-stream`. The connection stays open and the server pushes events as they occur.

#### Event Types

**`job`** — an OCR job to process:

```
id: evt-001
event: job
data: {"jobId":"job-789","documentId":"doc-456","fileDownloadUrl":"https://storage.example.com/presigned/image.png","callbackUrl":"https://api.example.com/api/v1/ocr-jobs/job-789/callback","language":"en"}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `jobId` | string | yes | Unique job identifier |
| `documentId` | string | no | Optional document reference |
| `fileDownloadUrl` | string | yes | Pre-signed URL to download the file for OCR |
| `callbackUrl` | string | yes | URL to POST the result to |
| `language` | string | no | Hint for OCR language |

**`ping`** — keepalive event (ignore):

```
event: ping
data: ok
```

#### Reconnection

If the connection drops:

1. Wait with exponential backoff: 1s → 2s → 4s → 8s → 16s → 30s (capped)
2. Reconnect to the same URL
3. Send `Last-Event-ID` header with the last received event `id` to resume

The server may also send a `retry:` field indicating the recommended reconnection delay in milliseconds.

---

### 3. Heartbeat (Push Only)

```
POST /api/v1/ocr-workers/:workerId/heartbeat
Content-Type: application/json
```

**Request body:**

```json
{
  "status": "idle",
  "activeJobs": 0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | `idle` or `busy` |
| `activeJobs` | int | Number of jobs currently in progress |

The heartbeat must be sent at the interval returned during registration. Missing heartbeats may cause the API server to mark the worker as offline and stop dispatching jobs.

> **Not needed for SSE workers.** The SSE connection itself proves the worker is alive.

---

### 4. Receive Job via Push (Worker Endpoint)

Available only for workers registered with `mode: "push"`. The API server sends this request to the worker's registered endpoint.

```
POST <workerEndpoint>/process
Content-Type: application/json
```

**Request body:**

```json
{
  "jobId": "job-789",
  "documentId": "doc-456",
  "fileDownloadUrl": "https://storage.example.com/presigned/image.png",
  "callbackUrl": "https://api.example.com/api/v1/ocr-jobs/job-789/callback",
  "language": "en"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `jobId` | string | yes | Unique job identifier |
| `documentId` | string | no | Optional document reference |
| `fileDownloadUrl` | string | yes | Pre-signed URL to download the file for OCR |
| `callbackUrl` | string | yes | URL to POST the result to |
| `language` | string | no | Hint for OCR language |

**Expected response:** `202 Accepted` with body:

```json
{
  "status": "accepted"
}
```

The worker should return 202 immediately and process the job asynchronously.

---

### 5. Post Callback (Result Delivery)

After processing, the worker POSTs the result to the `callbackUrl`. **This is the same for both SSE and Push models.**

```
POST <callbackUrl>
Content-Type: application/json
```

**Request body (success):**

```json
{
  "workerId": "w-abc123",
  "success": true,
  "ocrResult": {
    "text": "Recognized text content...",
    "boxes": [
      {
        "text": "Hello",
        "x": 10.0,
        "y": 20.0,
        "w": 100.0,
        "h": 30.0,
        "rect": {
          "topLeft_x": 10.0,
          "topLeft_y": 20.0,
          "topRight_x": 110.0,
          "topRight_y": 20.0,
          "bottomLeft_x": 10.0,
          "bottomLeft_y": 50.0,
          "bottomRight_x": 110.0,
          "bottomRight_y": 50.0
        }
      }
    ],
    "imageWidth": 1920,
    "imageHeight": 1080
  },
  "error": null,
  "processingTimeMs": 1234
}
```

**Request body (failure):**

```json
{
  "workerId": "w-abc123",
  "success": false,
  "ocrResult": null,
  "error": "Failed to download file",
  "processingTimeMs": 500
}
```

| Field | Type | Description |
|-------|------|-------------|
| `workerId` | string | The worker's ID from registration |
| `success` | bool | Whether OCR completed successfully |
| `ocrResult` | object? | OCR output (null on failure) |
| `ocrResult.text` | string | Full recognized text |
| `ocrResult.boxes` | array | Bounding boxes with text and coordinates |
| `ocrResult.imageWidth` | int | Source image width in pixels |
| `ocrResult.imageHeight` | int | Source image height in pixels |
| `error` | string? | Error message (null on success) |
| `processingTimeMs` | int | Processing time in milliseconds |

---

### 6. Unregister Worker

```
POST /api/v1/ocr-workers/:workerId/unregister
Content-Type: application/json
```

No request body required. Called on graceful shutdown. **Same for both models.**

---

## iOS OCR Server as a Worker

The iOS OCR Server app can operate as a worker in either SSE or Push mode. It uses Apple's Vision framework (`RecognizeTextRequest`) for OCR processing with support for:

- **Accurate** or **Fast** recognition levels
- Language correction
- Automatic language detection
- Image and PDF processing

### Configuration (Settings → OCR Worker)

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Worker | Activate worker mode | Off |
| Mode | SSE (recommended) or Push | SSE |
| API Host | URL of the central API server | (empty) |
| Worker Name | Name shown in the worker pool | `ocr-worker-ios` |
| Endpoint | (Push only) Worker's reachable URL | (auto) |
| Secret | Shared secret for authentication | (empty) |

> **Tip:** SSE mode is recommended for iPhones on cellular or behind NAT routers — no port forwarding or public IP needed.

### Architecture — SSE Mode

When worker mode is enabled with SSE:

1. `OcrWorkerSSEClient` registers with the API server (sends `mode: "sse"`)
2. Opens an SSE connection to `GET /api/v1/ocr-workers/:workerId/events`
3. Receives `event: job` events → downloads file → runs `TextRecognizer` → POSTs callback
4. On connection drop: reconnects with exponential backoff (1s → 2s → 4s → … → 30s max)
5. On app returning to foreground (`scenePhase == .active`): forces reconnect
6. Vapor HTTP server is **not started** unless "Enable HTTP Server" is also on

### Architecture — Push Mode

When worker mode is enabled with Push:

1. **Vapor HTTP server** starts (even if the "Enable HTTP Server" toggle is off) to accept pushed jobs on `POST /process`
2. `OcrWorkerClient` registers with the API server and starts the heartbeat loop
3. Incoming jobs on `/process` return **202 Accepted** immediately
4. `TextRecognizer` processes the image asynchronously
5. Result is POSTed to the callback URL with retry (3 attempts, exponential backoff)

### Files

| File | Purpose |
|------|---------|
| `OcrWorkerSSEClient.swift` | SSE-model client: register, SSE stream, job processing, callback |
| `OcrWorkerClient.swift` | Push-model client: register, heartbeat, job processing, callback |
| `Routes/WorkerRoute.swift` | (Push) `POST /process` endpoint definition |
| `VaporServerManager.swift` | Lifecycle coordination between HTTP server and worker modes |
| `Settings.swift` | Persists worker configuration via UserDefaults (including mode) |
| `SettingsView.swift` | UI for configuring worker settings with mode picker |

### Mode Matrix

The app supports running **HTTP server mode** and **worker mode** simultaneously or independently:

| HTTP Server | Worker (SSE) | Behavior |
|-------------|--------------|----------|
| On | On | Direct uploads + SSE worker. Vapor runs for uploads only. |
| Off | On | SSE worker-only. No Vapor server needed. |
| On | Off | Standard OCR server with `/upload` and `/upload-pdf` |
| Off | Off | All services disabled |

| HTTP Server | Worker (Push) | Behavior |
|-------------|---------------|----------|
| On | On | Full: both direct uploads and push-model worker active via Vapor |
| Off | On | Worker-only: Vapor starts for `/process` but no OCR upload routes |
| On | Off | Standard OCR server with `/upload` and `/upload-pdf` |
| Off | Off | All services disabled |

---

## Building a Custom Worker (Python Examples)

### SSE Worker (Recommended)

```python
"""Minimal SSE OCR worker using Tesseract."""

import io
import time
import threading
import requests
from PIL import Image
import pytesseract

# Configuration
API_HOST = "https://api.example.com"
WORKER_NAME = "ocr-worker-python"
SECRET = "your-shared-secret"

worker_id = None


def register():
    """Register with the API server in SSE mode."""
    global worker_id
    resp = requests.post(
        f"{API_HOST}/api/v1/ocr-workers/register",
        json={
            "name": WORKER_NAME,
            "capabilities": ["tesseract"],
            "secret": SECRET,
            "mode": "sse",
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    worker_id = data["workerId"]
    print(f"Registered as {worker_id}")


def process_and_callback(job_data):
    """Download file, run OCR, post result to callback."""
    job_id = job_data["jobId"]
    file_url = job_data["fileDownloadUrl"]
    callback_url = job_data["callbackUrl"]
    language = job_data.get("language")

    start = time.time()
    try:
        # Download
        resp = requests.get(file_url, timeout=60)
        resp.raise_for_status()
        image = Image.open(io.BytesIO(resp.content))
        w, h = image.size

        # OCR
        lang = language or "eng"
        text = pytesseract.image_to_string(image, lang=lang)

        elapsed_ms = int((time.time() - start) * 1000)
        payload = {
            "workerId": worker_id,
            "success": True,
            "ocrResult": {
                "text": text,
                "boxes": [],
                "imageWidth": w,
                "imageHeight": h,
            },
            "error": None,
            "processingTimeMs": elapsed_ms,
        }
    except Exception as e:
        elapsed_ms = int((time.time() - start) * 1000)
        payload = {
            "workerId": worker_id,
            "success": False,
            "ocrResult": None,
            "error": str(e),
            "processingTimeMs": elapsed_ms,
        }

    # Post callback with retry
    for attempt in range(3):
        try:
            requests.post(callback_url, json=payload, timeout=30)
            return
        except Exception:
            time.sleep(2**attempt)


def listen_sse():
    """Connect to SSE stream and process job events."""
    import json

    url = f"{API_HOST}/api/v1/ocr-workers/{worker_id}/events"
    headers = {
        "Accept": "text/event-stream",
        "Cache-Control": "no-cache",
        "Authorization": f"Bearer {SECRET}",
    }
    last_event_id = None
    attempt = 0
    max_delay = 30

    while True:
        try:
            if last_event_id:
                headers["Last-Event-ID"] = last_event_id

            with requests.get(url, headers=headers, stream=True, timeout=300) as resp:
                resp.raise_for_status()
                attempt = 0  # Reset backoff on successful connect
                print("SSE connected — waiting for jobs")

                event_type = None
                data_lines = []

                for line in resp.iter_lines(decode_unicode=True):
                    if line is None:
                        continue
                    line = line.rstrip("\r\n") if isinstance(line, str) else line

                    if line.startswith("event:"):
                        event_type = line[6:].strip()
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].strip())
                    elif line.startswith("id:"):
                        last_event_id = line[3:].strip()
                    elif line == "":
                        # End of event
                        if data_lines and event_type == "job":
                            full_data = "\n".join(data_lines)
                            job = json.loads(full_data)
                            print(f"Received job: {job['jobId']}")
                            threading.Thread(
                                target=process_and_callback,
                                args=(job,),
                            ).start()
                        event_type = None
                        data_lines = []

        except Exception as e:
            delay = min(max_delay, 2**attempt)
            attempt = min(attempt + 1, 5)
            print(f"SSE disconnected ({e}) — reconnecting in {delay}s")
            time.sleep(delay)


def unregister():
    """Unregister on shutdown."""
    if worker_id:
        try:
            requests.post(
                f"{API_HOST}/api/v1/ocr-workers/{worker_id}/unregister",
                timeout=10,
            )
        except Exception:
            pass


if __name__ == "__main__":
    import signal
    import sys

    register()

    def shutdown(sig, frame):
        print("Shutting down…")
        unregister()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    listen_sse()
```

### Push Worker

```python
"""Minimal push-model OCR worker using Tesseract."""

import io
import time
import threading
import requests
from flask import Flask, request, jsonify
from PIL import Image
import pytesseract

app = Flask(__name__)

# Configuration
API_HOST = "https://api.example.com"
WORKER_NAME = "ocr-worker-python"
WORKER_ENDPOINT = "http://your-public-ip:5000"
SECRET = "your-shared-secret"

worker_id = None
heartbeat_interval = 60


def register():
    """Register with the API server."""
    global worker_id, heartbeat_interval
    resp = requests.post(
        f"{API_HOST}/api/v1/ocr-workers/register",
        json={
            "name": WORKER_NAME,
            "endpoint": WORKER_ENDPOINT,
            "capabilities": ["tesseract"],
            "secret": SECRET,
            "mode": "push",
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    worker_id = data["workerId"]
    heartbeat_interval = data["heartbeatInterval"]
    print(f"Registered as {worker_id}, heartbeat every {heartbeat_interval}s")


def heartbeat_loop():
    """Send heartbeats in a background thread."""
    while True:
        time.sleep(heartbeat_interval)
        if worker_id:
            try:
                requests.post(
                    f"{API_HOST}/api/v1/ocr-workers/{worker_id}/heartbeat",
                    json={"status": "idle", "activeJobs": 0},
                    timeout=10,
                )
            except Exception as e:
                print(f"Heartbeat failed: {e}")


def process_and_callback(job_id, file_url, callback_url, language):
    """Download file, run OCR, post result to callback."""
    start = time.time()
    try:
        # Download
        resp = requests.get(file_url, timeout=60)
        resp.raise_for_status()
        image = Image.open(io.BytesIO(resp.content))
        w, h = image.size

        # OCR
        lang = language or "eng"
        text = pytesseract.image_to_string(image, lang=lang)

        elapsed_ms = int((time.time() - start) * 1000)
        payload = {
            "workerId": worker_id,
            "success": True,
            "ocrResult": {
                "text": text,
                "boxes": [],
                "imageWidth": w,
                "imageHeight": h,
            },
            "error": None,
            "processingTimeMs": elapsed_ms,
        }
    except Exception as e:
        elapsed_ms = int((time.time() - start) * 1000)
        payload = {
            "workerId": worker_id,
            "success": False,
            "ocrResult": None,
            "error": str(e),
            "processingTimeMs": elapsed_ms,
        }

    # Post callback with retry
    for attempt in range(3):
        try:
            requests.post(callback_url, json=payload, timeout=30)
            return
        except Exception:
            time.sleep(2**attempt)


@app.route("/process", methods=["POST"])
def receive_job():
    """Accept a pushed OCR job."""
    data = request.get_json()
    threading.Thread(
        target=process_and_callback,
        args=(
            data["jobId"],
            data["fileDownloadUrl"],
            data["callbackUrl"],
            data.get("language"),
        ),
    ).start()
    return jsonify({"status": "accepted"}), 202


if __name__ == "__main__":
    register()
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5000)
```

---

## Error Handling & Retry

### Callback Retry (Both Models)

Workers should retry the callback POST on failure. The iOS implementation uses:

- **3 attempts** with exponential backoff (1s, 2s, 4s)
- On all 3 failures, the result is lost — the API server should handle timeouts

### SSE Reconnection

If the SSE connection drops:

- Reconnect with **exponential backoff**: 1s → 2s → 4s → 8s → 16s → 30s (capped)
- Send `Last-Event-ID` header to resume from the last received event
- Reset backoff counter on successful reconnect
- On **401/403** response: stop reconnecting — the secret is invalid

The iOS app also reconnects automatically when it returns to foreground (`scenePhase == .active`).

### Registration Failure

If registration fails:
- **401/403**: Check the shared secret
- **Connection error**: Verify the API host URL and network connectivity
- **Other errors**: Retry with backoff, or alert the operator

### Heartbeat Failure (Push Only)

Heartbeat failures are non-fatal. The worker continues operating but the API server may mark it offline after missed heartbeats. The worker should continue sending heartbeats and will be re-acknowledged when connectivity returns.

---

## Security

1. **Shared secret** — passed during registration to authenticate the worker. For SSE, also sent as `Authorization: Bearer <secret>` on the event stream. Keep it out of version control and logs.
2. **HTTPS** — always use HTTPS in production for registration, SSE connections, and callback URLs.
3. **Pre-signed URLs** — file download URLs should be time-limited and scoped to the specific job.
4. **Network exposure** — SSE workers have no inbound surface. Push workers expose a `/process` endpoint that must be reachable by the API server — use proper firewall rules to restrict access.

---

## Best Practices

1. **Prefer SSE mode** for mobile workers, workers behind NAT, or environments where maintaining a public endpoint is impractical.

2. **Return 202 immediately** (Push only) — never block the `/process` handler on OCR processing. Accept the job and process asynchronously.

3. **Include processing time** — the `processingTimeMs` field helps the API server monitor worker performance and detect degradation.

4. **Scale horizontally** — register multiple worker instances. The API server uses round-robin or load-based selection across the worker pool.

5. **Handle graceful shutdown** — always call the unregister endpoint on shutdown to immediately remove the worker from the pool.

6. **Handle reconnection** (SSE) — always implement exponential backoff and `Last-Event-ID` support. Do not reconnect in a tight loop.

7. **Monitor connection health** (SSE) — if you don't receive any events (including `ping`) for an extended period, the connection may be silently broken. Consider a client-side timeout to force reconnection.

8. **Keep the endpoint reachable** (Push only) — the API server must be able to POST to the worker's endpoint. Use a public IP, reverse proxy, or tunnel (e.g. ngrok) for development.

9. **Monitor heartbeat health** (Push only) — if heartbeats are failing, the API server may stop sending jobs. Log heartbeat failures for debugging.
