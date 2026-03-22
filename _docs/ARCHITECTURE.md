# iOS OCR Server — Architecture

## Overview

iOS OCR Server turns an iPhone into a local OCR processing node. It runs a Vapor HTTP server on the device, accepting image and PDF uploads via REST API and returning structured OCR results using Apple's Vision framework.

The app can operate in two modes simultaneously:

1. **HTTP Server mode** — direct OCR via `/upload` and `/upload-pdf` endpoints
2. **Worker mode** — push-model worker that registers with a central API server and receives jobs

---

## System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        iPhone App                           │
│                                                             │
│  ┌──────────────┐     ┌──────────────┐                      │
│  │  SwiftUI UI  │────▶│VaporServer   │◀── Vapor 4 (actor)   │
│  │  (MainActor) │     │  Manager     │                      │
│  └──────┬───────┘     └──────┬───────┘                      │
│         │                    │                               │
│         │              ┌─────┴──────┐                        │
│         │              │ VaporServer │ ─── HTTP listener     │
│         │              │   (actor)   │     0.0.0.0:port      │
│         │              └─────┬──────┘                        │
│         │                    │                               │
│         │         ┌──────────┼──────────┐                    │
│         │         │          │          │                    │
│         │    ┌────┴───┐ ┌───┴────┐ ┌───┴────────┐           │
│         │    │  Home  │ │  OCR   │ │  Worker     │           │
│         │    │ Route  │ │ Routes │ │  Route      │           │
│         │    │ GET /  │ │ POST   │ │ POST        │           │
│         │    │        │ │/upload │ │/process     │           │
│         │    └────────┘ └───┬────┘ └──────┬─────┘           │
│         │                   │             │                  │
│         │              ┌────┴─────────────┴───┐              │
│         │              │   TextRecognizer     │              │
│         │              │  (Vision + PDFKit)   │              │
│         │              └──────────────────────┘              │
│         │                                                    │
│   ┌─────┴───────────┐                                        │
│   │ OcrWorkerClient │──── register / heartbeat / callback    │
│   │   (@MainActor)  │     to external API server             │
│   └─────────────────┘                                        │
│                                                              │
│   ┌─────────────────┐                                        │
│   │    Settings      │──── UserDefaults (Sendable singleton) │
│   └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

---

## Module Boundaries

### Core Layer (no Vapor dependency)

| File | Responsibility |
|------|----------------|
| `Models/OCRModels.swift` | `OCRRectItem`, `OCRBoxItem`, `OCRResult`, `OCRPageResult` — plain `Codable + Sendable` |
| `TextRecognizer.swift` | Image/PDF → OCR via Vision framework. Returns `OCRResult` / `[OCRPageResult]` |
| `Settings.swift` | Singleton (`final class Settings: Sendable`), UserDefaults-backed |

### HTTP Layer (Vapor)

| File | Responsibility |
|------|----------------|
| `VaporServer.swift` | Actor managing Vapor `Application` lifecycle (start / stop / restart) |
| `VaporServerManager.swift` | `@MainActor` coordinator — configures server + worker, publishes UI state |
| `Models/APIResponses.swift` | `Content` conformance + HTTP-specific response envelopes |
| `Routes/HomeRoute.swift` | `GET /` landing page |
| `Routes/OcrRoutes.swift` | `POST /upload`, `POST /upload-pdf` — direct OCR |
| `Routes/RouteHelpers.swift` | Shared helpers: `byteBufferToData`, `htmlResponse`, `jsonResponse` |
| `Routes/WorkerRoute.swift` | `POST /process` — receives pushed OCR jobs |
| `Templates/HTMLTemplates.swift` | HTML string generation (home page, result page) |

### Worker Layer

| File | Responsibility |
|------|----------------|
| `OcrWorkerClient.swift` | Push-model client: register → heartbeat → process → callback |

### UI Layer (SwiftUI)

| File | Responsibility |
|------|----------------|
| `ContentView.swift` | Main screen: status, IP addresses, server/worker indicators |
| `SettingsView.swift` | Configuration: recognition, HTTP server, OCR worker |
| `OcrTestView.swift` | In-app web view OCR test |
| `DonationView.swift` | StoreKit IAP for donations |
| `ReadmeView.swift` | Embedded README display |
| `RecognitionLevelView.swift` | Recognition level picker |

### Monitor Layer

| File | Responsibility |
|------|----------------|
| `Monitor/AppMonitor.swift` | App-level performance monitoring |
| `Monitor/SystemMonitor.swift` | System resource sampling |
| `Monitor/DashboardView.swift` | Real-time dashboard UI |
| `Monitor/Sampler.swift` | Periodic resource sampler |
| `Monitor/LineChart.swift` | Chart visualization |

---

## Concurrency Model

| Component | Isolation | Why |
|-----------|-----------|-----|
| `VaporServer` | `actor` | Protects Vapor `Application` state from data races |
| `VaporServerManager` | `@MainActor` | Publishes `@Published` properties to SwiftUI |
| `OcrWorkerClient` | `@MainActor` | Publishes state, receives configuration from UI |
| `Settings` | `Sendable` (final class) | Thread-safe via `UserDefaults` |
| `TextRecognizer` | Undecorated class | Stateless after init; `async` methods are safe |
| Route handlers | Vapor's event loop | Vapor manages concurrency per request |

### Key Patterns

- **`nonisolated func processJob(...) async`** on `OcrWorkerClient` — allows concurrent job processing without blocking the MainActor
- **`Task { ... }` in route handlers** — fire-and-forget for async OCR processing (returns 202 immediately)
- **`actor` for VaporServer** — all configuration mutations are serialized

---

## Data Flow

### Direct OCR (HTTP Server mode)

```
Client → POST /upload (multipart) → OcrRoutes
  → byteBufferToData() → TextRecognizer.getOcrResult()
  → JSON/HTML response to client
```

### Push-model Worker

```
API Server → POST /process on worker → WorkerRoute
  → 202 Accepted immediately
  → Task: download file → TextRecognizer.getOcrResult()
  → POST callback with result (retry 3x with exponential backoff)
```

### Startup Sequence

```
OcrServerApp → VaporServerManager.init()
  → startServer()
    → setupParameters() — reads Settings
    → VaporServer.start() — binds port
    → registerHomeRoute / registerOcrRoutes / registerWorkerRoute
    → startWorkerIfNeeded() — OcrWorkerClient.start()
      → register with API server → start heartbeat
```

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| [Vapor](https://vapor.codes) | 4.115.1 | HTTP server framework |
| Apple Vision | iOS 18.4+ | `RecognizeTextRequest` for OCR |
| Apple PDFKit | Built-in | PDF rendering at 300 DPI |
| Apple StoreKit | Built-in | In-app purchase (donations) |

---

## Configuration

All settings persisted via `UserDefaults` through `Settings.shared`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `httpPort` | Int | 8000 | Server listening port |
| `recognitionLevel` | String | "Accurate" | "Accurate" or "Fast" |
| `languageCorrection` | Bool | true | Apply language correction |
| `automaticallyDetectsLanguage` | Bool | true | Auto language detection |
| `httpServerEnabled` | Bool | true | Enable direct OCR endpoints |
| `workerEnabled` | Bool | false | Enable push-model worker |
| `workerName` | String | "ocr-worker-ios" | Worker identifier |
| `workerApiHost` | String | "" | Central API server URL |
| `workerEndpoint` | String | "" | Worker's reachable URL (auto-detected if empty) |
| `workerSecret` | String | "" | Shared authentication secret |
