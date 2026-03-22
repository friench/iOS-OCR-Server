//
//  JobQueueClient.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/8.
//

import Foundation
import Vision

/// A lightweight polling client that connects to an external job-queue server,
/// picks up pending OCR jobs, runs recognition, and posts the results back.
///
/// Expected queue API contract
/// ───────────────────────────
/// • Fetch next job   GET  {host}/job          (returns 200+JSON or 204 when empty)
/// • Submit result    POST {host}/job/{id}/result
///
/// Job JSON:
/// ```json
/// { "id": "abc123", "image_url": "https://…" }
/// ```
/// or with inline base-64 image data:
/// ```json
/// { "id": "abc123", "image_base64": "<base64>" }
/// ```
///
/// Result JSON posted back:
/// ```json
/// {
///   "id": "abc123",
///   "success": true,
///   "ocr_result": "Hello\nWorld",
///   "image_width": 640,
///   "image_height": 480,
///   "ocr_boxes": [ … ]
/// }
/// ```

@MainActor
final class JobQueueClient: ObservableObject {

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var statusMessage: String = ""
    @Published var processedCount: Int = 0

    // MARK: - Private

    private var pollTask: Task<Void, Never>?

    private var host: String = ""
    private var apiKey: String = ""

    private var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate
    private var usesLanguageCorrection: Bool = true
    private var automaticallyDetectsLanguage: Bool = true

    // Seconds between poll requests when no job is available
    private let idlePollInterval: TimeInterval = 3
    // Seconds between polls when a job was just processed (backpressure)
    private let activePollInterval: TimeInterval = 0.5
    // Seconds to wait after a connection error before retrying
    private let errorRetryInterval: TimeInterval = 10

    // MARK: - Public API

    func configure(
        host: String,
        apiKey: String,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) {
        self.host = host
        self.apiKey = apiKey
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }

    func start() {
        guard !isRunning else { return }
        guard !host.isEmpty else {
            statusMessage = String(localized: "Job queue host is not configured")
            return
        }
        isRunning = true
        statusMessage = String(localized: "Connecting to job queue…")
        pollTask = Task { [weak self] in
            await self?.pollLoop()
            // If the task finishes unexpectedly (self deallocated), reset state
            await MainActor.run { [weak self] in
                self?.isRunning = false
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        statusMessage = String(localized: "Job queue disconnected")
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        while !Task.isCancelled {
            let result = await fetchAndProcessJob()
            let delay: TimeInterval
            switch result {
            case .processed:
                delay = activePollInterval
            case .empty:
                delay = idlePollInterval
            case .connectionError(let message):
                statusMessage = message
                delay = errorRetryInterval
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private enum PollResult {
        case processed
        case empty
        case connectionError(String)
    }

    /// Fetches one job, performs OCR, posts the result.
    private func fetchAndProcessJob() async -> PollResult {
        let fetchResult = await fetchNextJob()
        switch fetchResult {
        case .noJob:
            statusMessage = String(localized: "Waiting for jobs…")
            return .empty
        case .error(let message):
            return .connectionError(message)
        case .job(let job):
            guard let imageData = await loadImageData(from: job) else {
                await postResult(jobId: job.id, success: false, ocrResult: nil)
                return .processed
            }

            let recognizer = TextRecognizer(
                recognitionLevel: recognitionLevel,
                usesLanguageCorrection: usesLanguageCorrection,
                automaticallyDetectsLanguage: automaticallyDetectsLanguage
            )

            let result = await recognizer.getOcrResult(data: imageData)
            await postResult(jobId: job.id, success: result != nil, ocrResult: result)

            await MainActor.run {
                processedCount += 1
                statusMessage = String(format: NSLocalizedString("Jobs processed: %d", comment: "Job queue processed count"), processedCount)
            }

            return .processed
        }
    }

    // MARK: - Networking helpers

    private struct JobPayload: Decodable {
        let id: String
        let image_url: String?
        let image_base64: String?
    }

    private struct JobResultPayload: Encodable {
        let id: String
        let success: Bool
        let ocr_result: String
        let image_width: Int
        let image_height: Int
        let ocr_boxes: [OCRBoxItem]
    }

    private enum FetchResult {
        case job(JobPayload)
        case noJob          // 204 or empty queue
        case error(String)  // network / auth / server error
    }

    private func makeBaseURL() -> URL? {
        var urlString = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "http://" + urlString
        }
        return URL(string: urlString)
    }

    private func addAPIKey(to request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
    }

    private func fetchNextJob() async -> FetchResult {
        guard let base = makeBaseURL() else {
            return .error(String(localized: "Invalid host URL"))
        }
        let url = base.appendingPathComponent("job")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        addAPIKey(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error(String(localized: "Invalid server response"))
            }
            switch httpResponse.statusCode {
            case 200:
                do {
                    let job = try JSONDecoder().decode(JobPayload.self, from: data)
                    return .job(job)
                } catch {
                    return .error(String(localized: "Failed to parse job"))
                }
            case 204:
                return .noJob
            case 401, 403:
                return .error(String(localized: "Authentication failed — check API key"))
            case 500...599:
                return .error(String(format: NSLocalizedString("Server error (%d)", comment: "Job queue server error with status code"), httpResponse.statusCode))
            default:
                return .noJob
            }
        } catch {
            return .error(String(format: NSLocalizedString("Connection error: %@", comment: "Job queue connection error"), error.localizedDescription))
        }
    }

    private func loadImageData(from job: JobPayload) async -> Data? {
        // Prefer inline base-64 data
        if let b64 = job.image_base64, !b64.isEmpty {
            return Data(base64Encoded: b64)
        }
        // Fall back to downloading from URL
        if let urlString = job.image_url, let url = URL(string: urlString) {
            return try? await URLSession.shared.data(from: url).0
        }
        return nil
    }

    private func postResult(jobId: String, success: Bool, ocrResult: OCRResult?) async {
        guard let base = makeBaseURL() else { return }
        let url = base.appendingPathComponent("job/\(jobId)/result")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAPIKey(to: &request)

        let payload = JobResultPayload(
            id: jobId,
            success: success,
            ocr_result: ocrResult?.text ?? "",
            image_width: ocrResult?.image_width ?? 0,
            image_height: ocrResult?.image_height ?? 0,
            ocr_boxes: ocrResult?.boxes ?? []
        )

        guard let body = try? JSONEncoder().encode(payload) else { return }
        request.httpBody = body

        _ = try? await URLSession.shared.data(for: request)
    }
}
