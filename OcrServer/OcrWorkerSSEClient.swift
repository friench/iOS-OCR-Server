//
//  OcrWorkerSSEClient.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Foundation
import Vision

/// SSE-based OCR worker client.
///
/// Lifecycle:
/// 1. Register with the API server (`POST /api/v1/ocr-workers/register`)
/// 2. Connect to SSE stream (`GET /api/v1/ocr-workers/:workerId/events`)
/// 3. Receive job events from the stream, process OCR, POST callback
/// 4. Auto-reconnect on stream interruption (exponential backoff)
/// 5. Unregister on stop (`POST /api/v1/ocr-workers/:workerId/unregister`)
///
/// No heartbeat needed — the SSE connection itself proves liveness.
/// No public endpoint needed — all connections are outbound (NAT-friendly).
@MainActor
final class OcrWorkerSSEClient: ObservableObject {

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = ""
    @Published var processedCount: Int = 0

    // MARK: - Registration state

    private(set) var workerId: String?

    // MARK: - Configuration

    private var apiHost: String = ""
    private var secret: String = ""
    private var workerName: String = "ocr-worker-ios"

    private var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    private var usesLanguageCorrection: Bool = true
    private var automaticallyDetectsLanguage: Bool = true

    // MARK: - Tasks

    private var sseTask: Task<Void, Never>?
    private var activeJobs: Int = 0
    private static let maxReconnectDelay: UInt64 = 30

    // MARK: - Public API

    func configure(
        apiHost: String,
        secret: String,
        workerName: String,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) {
        self.apiHost = apiHost
        self.secret = secret
        self.workerName = workerName
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

        statusMessage = String(localized: "Registering worker…")

        let result = await register()
        switch result {
        case .success(let registration):
            workerId = registration.workerId
            isRunning = true
            statusMessage = String(localized: "Connecting to SSE…")
            startSSE()
        case .failure(let message):
            statusMessage = message
        }
    }

    func stop() async {
        guard isRunning else { return }
        sseTask?.cancel()
        sseTask = nil

        if workerId != nil {
            await unregister()
        }

        workerId = nil
        isRunning = false
        statusMessage = String(localized: "Worker disconnected")
    }

    /// Called when app returns to foreground — force reconnect.
    func reconnect() {
        guard isRunning, workerId != nil else { return }
        sseTask?.cancel()
        sseTask = nil
        statusMessage = String(localized: "Reconnecting…")
        startSSE()
    }

    // MARK: - SSE Stream

    private func startSSE() {
        guard let baseURL = makeBaseURL(), let wid = workerId else { return }

        sseTask = Task { [weak self] in
            var attempt: UInt64 = 0
            var lastEventId: String?

            while !Task.isCancelled {
                guard let self else { return }

                let url = baseURL.appendingPathComponent("api/v1/ocr-workers/\(wid)/events")
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                if let secret = await self.secretHeaderValue() {
                    request.setValue(secret, forHTTPHeaderField: "Authorization")
                }
                if let lastId = lastEventId {
                    request.setValue(lastId, forHTTPHeaderField: "Last-Event-ID")
                }
                // Keep connection alive for a long time
                request.timeoutInterval = 300

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw SSEError.invalidResponse
                    }

                    guard httpResponse.statusCode == 200 else {
                        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                            await MainActor.run {
                                self.statusMessage = String(localized: "Authentication failed — check secret")
                                self.isRunning = false
                            }
                            return
                        }
                        throw SSEError.httpError(httpResponse.statusCode)
                    }

                    // Connected successfully — reset backoff
                    attempt = 0
                    await MainActor.run {
                        self.statusMessage = String(localized: "SSE connected — waiting for jobs")
                    }

                    // Parse SSE stream
                    var eventType: String?
                    var dataLines: [String] = []

                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }

                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        } else if line.hasPrefix("id:") {
                            lastEventId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        } else if line.isEmpty {
                            // End of event — dispatch
                            if !dataLines.isEmpty {
                                let fullData = dataLines.joined(separator: "\n")
                                await self.handleEvent(type: eventType, data: fullData)
                            }
                            eventType = nil
                            dataLines.removeAll()
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }

                // Connection dropped — reconnect with backoff
                let delay = min(Self.maxReconnectDelay, UInt64(pow(2.0, Double(attempt))))
                attempt = min(attempt + 1, 5) // cap exponent

                await MainActor.run {
                    self.statusMessage = String(
                        format: NSLocalizedString("SSE disconnected — reconnecting in %ds", comment: ""),
                        delay
                    )
                }

                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    private enum SSEError: Error {
        case invalidResponse
        case httpError(Int)
    }

    // MARK: - Event Handling

    private struct JobEvent: Decodable {
        let jobId: String
        let documentId: String?
        let fileDownloadUrl: String
        let callbackUrl: String
        let language: String?
    }

    private func handleEvent(type: String?, data: String) async {
        switch type {
        case "job":
            guard let jsonData = data.data(using: .utf8),
                  let job = try? JSONDecoder().decode(JobEvent.self, from: jsonData) else {
                return
            }
            activeJobs += 1
            statusMessage = String(
                format: NSLocalizedString("Processing job %@…", comment: ""),
                job.jobId
            )
            Task {
                await processJob(
                    jobId: job.jobId,
                    fileDownloadUrl: job.fileDownloadUrl,
                    callbackUrl: job.callbackUrl,
                    language: job.language
                )
            }
        case "ping":
            break // keepalive, ignore
        default:
            break
        }
    }

    // MARK: - Job Processing

    nonisolated func processJob(
        jobId: String,
        fileDownloadUrl: String,
        callbackUrl: String,
        language: String?
    ) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Download file
        guard let url = URL(string: fileDownloadUrl),
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            await postCallback(callbackUrl: callbackUrl, success: false, error: "Failed to download file", result: nil, startTime: startTime)
            await decrementActiveJobs()
            return
        }

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
            success: ocrResult != nil,
            error: ocrResult == nil ? "OCR processing failed" : nil,
            result: ocrResult,
            startTime: startTime
        )

        await MainActor.run {
            self.processedCount += 1
            self.activeJobs -= 1
            self.statusMessage = String(
                format: NSLocalizedString("Jobs processed: %d", comment: ""),
                self.processedCount
            )
        }
    }

    private func decrementActiveJobs() async {
        await MainActor.run { self.activeJobs -= 1 }
    }

    // MARK: - Registration

    private struct RegisterRequest: Encodable {
        let name: String
        let capabilities: [String]
        let secret: String?
        let mode: String
    }

    private struct RegisterResponse: Decodable {
        let workerId: String
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
            capabilities: ["apple-vision"],
            secret: secret.isEmpty ? nil : secret,
            mode: "sse"
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

    nonisolated private func secretHeaderValue() async -> String? {
        let s = await self.secret
        return s.isEmpty ? nil : "Bearer \(s)"
    }

    private func makeBaseURL() -> URL? {
        var urlString = apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        return URL(string: urlString)
    }
}
