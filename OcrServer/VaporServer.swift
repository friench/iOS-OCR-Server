//
//  VaporServer.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor
import Vision

actor VaporServer {
    private var app: Application?
    private var runTask: Task<Void, Never>?

    private var shouldAutoRestart = true
    private var onStopped: (@Sendable () -> Void)?

    let host: String = "0.0.0.0"
    let environment: Environment = .production

    var port: Int = 8000

    // OCR parameters
    var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    var usesLanguageCorrection: Bool = true
    var automaticallyDetectsLanguage: Bool = true

    // Whether to register /upload and /upload-pdf routes
    var ocrRoutesEnabled: Bool = true

    private(set) var isRunning: Bool = false

    // MARK: - Public API

    func setOnStopped(_ handler: @escaping @Sendable () -> Void) {
        self.onStopped = handler
    }

    func setAutoRestart(_ enabled: Bool) {
        self.shouldAutoRestart = enabled
    }

    func start() async throws {
        guard runTask == nil else { return }

        let app = try await Application.make(environment)
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        // Register routes
        registerHomeRoute(on: app, port: port)

        if ocrRoutesEnabled {
            registerOcrRoutes(
                on: app,
                recognitionLevel: recognitionLevel,
                usesLanguageCorrection: usesLanguageCorrection,
                automaticallyDetectsLanguage: automaticallyDetectsLanguage
            )
        }

        self.app = app
        isRunning = true

        runTask = Task { [weak app, weak self] in
            guard let self = self else { return }
            var hadError = false
            do {
                try await app?.execute()
            } catch {
                hadError = true
            }

            if let cb = await self.onStopped { cb() }

            if await self.shouldAutoRestart && hadError {
                await self.cleanupAfterStop()
                NotificationCenter.default.post(
                    name: .vaporServerShouldRestart,
                    object: nil,
                    userInfo: ["reason": "crash"]
                )
            }
        }
    }

    func stop() async {
        guard let app = app else { return }
        try? await app.asyncShutdown()
        self.cleanupAfterStop()
    }

    func restart() async throws {
        await stop()
        try await start()
    }

    func running() -> Bool { isRunning }

    func configure(
        port: Int? = nil,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel? = nil,
        usesLanguageCorrection: Bool? = nil,
        automaticallyDetectsLanguage: Bool? = nil,
        ocrRoutesEnabled: Bool? = nil
    ) {
        if let v = port { self.port = v }
        if let v = recognitionLevel { self.recognitionLevel = v }
        if let v = usesLanguageCorrection { self.usesLanguageCorrection = v }
        if let v = automaticallyDetectsLanguage { self.automaticallyDetectsLanguage = v }
        if let v = ocrRoutesEnabled { self.ocrRoutesEnabled = v }
    }

    /// Provides access to the underlying Vapor `Application` for registering
    /// additional routes (e.g. the worker `/process` endpoint).
    func application() -> Application? { app }

    // MARK: - Private

    private func cleanupAfterStop() {
        runTask = nil
        app = nil
        isRunning = false
    }
}

extension Notification.Name {
    static let vaporServerShouldRestart = Notification.Name("vaporServerShouldRestart")
}
