//
//  OcrWorkerClient.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Foundation
import Vision

/// Push-model OCR worker client.
///
/// Lifecycle:
/// 1. Register with the API server (`POST /api/v1/ocr-workers/register`)
/// 2. Start heartbeat loop (interval from registration response)
/// 3. Receive jobs via `POST /process` on the Vapor server (see WorkerRoute)
/// 4. Unregister on stop (`POST /api/v1/ocr-workers/:workerId/unregister`)
///
/// This client does NOT poll for jobs. The API server pushes jobs to the
/// worker's `/process` endpoint.
@MainActor
final class OcrWorkerClient: ObservableObject {

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = ""
    @Published var processedCount: Int = 0

    // MARK: - Registration state

    private(set) var workerId: String?
    private var heartbeatInterval: Int = 60

    // MARK: - Configuration

    private var apiHost: String = ""
    private var secret: String = ""
    private var workerName: String = "ocr-worker-ios"
    private var workerEndpoint: String = ""

    private var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    private var usesLanguageCorrection: Bool = true
    private var automaticallyDetectsLanguage: Bool = true

    // MARK: - Tasks

    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Public API

    func configure(
        apiHost: String,
        secret: String,
        workerName: String,
        workerEndpoint: String,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) {
        self.apiHost = apiHost
        self.secret = secret
        self.workerName = workerName
        self.workerEndpoint = workerEndpoint
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }

    func start() async {
        guard !isRunning else { return }
        guard !apiHost.isEmpty else {
            statusMessage = String(localized: "Worker API host is not configured")
            return
        }
        guard !workerEndpoint.isEmpty else {
            statusMessage = String(localized: "Worker endpoint is not configured")
            return
        }

        statusMessage = String(localized: "Registering worker…")

        let result = await register()
        switch result {
        case .success(let registration):
            workerId = registration.workerId
            heartbeatInterval = registration.heartbeatInterval
            isRunning = true
            statusMessage = String(localized: "Worker registered")
            startHeartbeat()
        case .failure(let message):
            statusMessage = message
        }
    }

    func stop() async {
        guard isRunning else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if workerId != nil {
            await unregister()
        }

        workerId = nil
        isRunning = false
        statusMessage = String(localized: "Worker disconnected")
    }

    /// Called by WorkerRoute when a job is pushed to `/process`.
    /// Runs OCR and posts the result to the callback URL.
    nonisolated func processJob(
        jobId: String,
        fileDownloadUrl: String,
        callbackUrl: String,
        language: String?
    ) async {
        // Download file
        guard let url = URL(string: fileDownloadUrl),
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            await postCallback(callbackUrl: callbackUrl, jobId: jobId, success: false, error: "Failed to download file", result: nil, startTime: CFAbsoluteTimeGetCurrent())
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Read OCR config from MainActor
        let level = await self.recognitionLevel
        let langCorrection = await self.usesLanguageCorrection
        let autoDetect = await self.automaticallyDetectsLanguage

        let recognizer = TextRecognizer(
            recognitionLevel: level,
            usesLanguageCorrection: langCorrection,
            automaticallyDetectsLanguage: autoDetect
        )

        let ocrResult = await recognizer.getOcrResult(data: data)

        await postCallback(
            callbackUrl: callbackUrl,
            jobId: jobId,
            success: ocrResult != nil,
            error: ocrResult == nil ? "OCR processing failed" : nil,
            result: ocrResult,
            startTime: startTime
        )

        await MainActor.run {
            self.processedCount += 1
            self.statusMessage = String(
                format: NSLocalizedString("Jobs processed: %d", comment: ""),
                self.processedCount
            )
        }
    }

    // MARK: - Registration

    private struct RegisterRequest: Encodable {
        let name: String
        let endpoint: String
        let capabilities: [String]
        let secret: String?
    }

    private struct RegisterResponse: Decodable {
        let workerId: String
        let heartbeatInterval: Int
    }

    private enum RegistrationResult {
        case success(RegisterResponse)
        case failure(String)
    }

    private func register() async -> RegistrationResult {
        guard let baseURL = makeBaseURL() else {
            return .failure(String(localized: "Invalid API host URL"))
        }

        let url = baseURL.appendingPathComponent("api/v1/ocr-workers/register")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RegisterRequest(
            name: workerName,
            endpoint: workerEndpoint,
            capabilities: ["apple-vision"],
            secret: secret.isEmpty ? nil : secret
        )

        guard let body = try? JSONEncoder().encode(payload) else {
            return .failure(String(localized: "Failed to encode registration"))
        }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(String(localized: "Invalid server response"))
            }

            switch httpResponse.statusCode {
            case 200, 201:
                do {
                    let reg = try JSONDecoder().decode(RegisterResponse.self, from: data)
                    return .success(reg)
                } catch {
                    return .failure(String(localized: "Failed to parse registration response"))
                }
            case 401, 403:
                return .failure(String(localized: "Authentication failed — check secret"))
            default:
                return .failure(String(
                    format: NSLocalizedString("Registration failed (%d)", comment: ""),
                    httpResponse.statusCode
                ))
            }
        } catch {
            return .failure(String(
                format: NSLocalizedString("Connection error: %@", comment: ""),
                error.localizedDescription
            ))
        }
    }

    private func unregister() async {
        guard let baseURL = makeBaseURL(), let wid = workerId else { return }
        let url = baseURL.appendingPathComponent("api/v1/ocr-workers/\(wid)/unregister")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.heartbeatInterval ?? 60) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.sendHeartbeat()
            }
        }
    }

    private struct HeartbeatRequest: Encodable {
        let status: String
        let activeJobs: Int
    }

    private func sendHeartbeat() async {
        guard let baseURL = makeBaseURL(), let wid = workerId else { return }
        let url = baseURL.appendingPathComponent("api/v1/ocr-workers/\(wid)/heartbeat")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = HeartbeatRequest(status: "idle", activeJobs: 0)
        guard let body = try? JSONEncoder().encode(payload) else { return }
        request.httpBody = body

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Callback

    private struct CallbackPayload: Encodable {
        let workerId: String
        let success: Bool
        let ocrResult: CallbackOCRResult?
        let error: String?
        let processingTimeMs: Int
    }

    private struct CallbackOCRResult: Encodable {
        let text: String
        let boxes: [OCRBoxItem]
        let imageWidth: Int
        let imageHeight: Int
    }

    nonisolated private func postCallback(
        callbackUrl: String,
        jobId: String,
        success: Bool,
        error: String?,
        result: OCRResult?,
        startTime: CFAbsoluteTime
    ) async {
        guard let url = URL(string: callbackUrl) else { return }

        let wid = await self.workerId ?? ""
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ocrResult: CallbackOCRResult? = result.map {
            CallbackOCRResult(text: $0.text, boxes: $0.boxes, imageWidth: $0.image_width, imageHeight: $0.image_height)
        }

        let payload = CallbackPayload(
            workerId: wid,
            success: success,
            ocrResult: ocrResult,
            error: error,
            processingTimeMs: elapsedMs
        )

        guard let body = try? JSONEncoder().encode(payload) else { return }
        request.httpBody = body

        // Retry up to 3 times with exponential backoff
        for attempt in 0..<3 {
            if let _ = try? await URLSession.shared.data(for: request) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
        }
    }

    // MARK: - Helpers

    private func makeBaseURL() -> URL? {
        var urlString = apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        return URL(string: urlString)
    }
}
