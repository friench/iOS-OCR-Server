# iOS OCR Server — Project Structure

## Directory Layout

```
iOS-OCR-Server/
├── _docs/                          # Documentation
│   ├── ARCHITECTURE.md             # System design and module overview
│   ├── API_REFERENCE.md            # HTTP API documentation
│   ├── PROJECT_STRUCTURE.md        # This file
│   └── WORKER_DEVELOPMENT_GUIDE.md # Push-model worker protocol
│
├── OcrServer/                      # Main app source
│   ├── OcrServerApp.swift          # @main entry point
│   ├── ContentView.swift           # Main screen (status, IP addresses)
│   ├── SettingsView.swift          # Settings UI
│   ├── Settings.swift              # UserDefaults-backed configuration
│   │
│   ├── VaporServer.swift           # Vapor HTTP server (actor)
│   ├── VaporServerManager.swift    # Server + worker lifecycle coordinator
│   ├── TextRecognizer.swift        # Vision framework OCR engine
│   ├── OcrWorkerClient.swift       # Push-model worker client
│   │
│   ├── Models/
│   │   ├── OCRModels.swift         # Core data models (no Vapor dependency)
│   │   └── APIResponses.swift      # Vapor Content response types
│   │
│   ├── Routes/
│   │   ├── HomeRoute.swift         # GET /
│   │   ├── OcrRoutes.swift         # POST /upload, POST /upload-pdf
│   │   ├── WorkerRoute.swift       # POST /process (worker mode)
│   │   └── RouteHelpers.swift      # Shared route utilities
│   │
│   ├── Templates/
│   │   └── HTMLTemplates.swift     # HTML page generation
│   │
│   ├── Monitor/                    # Performance monitoring subsystem
│   │   ├── AppMonitor.swift
│   │   ├── SystemMonitor.swift
│   │   ├── Sampler.swift
│   │   ├── DashboardView.swift
│   │   ├── LineChart.swift
│   │   ├── Cards.swift
│   │   ├── ResourceSnapshot.swift
│   │   └── Utilities.swift
│   │
│   ├── DonationView.swift          # StoreKit IAP
│   ├── OcrTestView.swift           # In-app OCR test (WebView)
│   ├── ReadmeView.swift            # Embedded README viewer
│   ├── RecognitionLevelView.swift  # Recognition level picker
│   ├── WebView.swift               # WKWebView wrapper
│   │
│   ├── Localizable.xcstrings       # Localization strings
│   ├── Assets.xcassets/            # Asset catalog
│   └── ocrserver_icon.icon/        # App icon
│
├── OcrServer.xcodeproj/            # Xcode project
│   └── project.pbxproj
│
├── README.md                       # English README
├── README.ja.md                    # Japanese
├── README.zh-TW.md                 # Traditional Chinese
├── README.zh-CN.md                 # Simplified Chinese
├── README.ko.md                    # Korean
├── README.fr.md                    # French
└── LICENSE
```

## Key Conventions

- **fileSystemSynchronizedGroups** — Xcode auto-discovers new files in the `OcrServer/` directory. No need to manually add files to the project.
- **No package.json / SPM Package.swift** — Vapor is added as an Xcode Swift Package dependency (resolved in `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).
- **Models vs APIResponses** — `OCRModels.swift` has no Vapor imports and can be used anywhere. `APIResponses.swift` adds Vapor `Content` conformance extensions.
- **Routes are free functions** — each `register*Route(on:...)` function takes an `Application` and registers its routes. This keeps VaporServer lean.
