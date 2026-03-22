//
//  WorkerRoute.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import Vapor

/// Incoming job payload pushed by the API server to `POST /process`.
struct WorkerJobPayload: Content {
    let jobId: String
    let documentId: String?
    let fileDownloadUrl: String
    let callbackUrl: String
    let language: String?
}

/// Registers `POST /process` — the endpoint that receives OCR jobs
/// from the API server (push model).
func registerWorkerRoute(on app: Application, workerClient: OcrWorkerClient) {
    app.on(.POST, "process", body: .collect(maxSize: "1mb")) { req async throws -> Response in
        let payload: WorkerJobPayload
        do {
            payload = try req.content.decode(WorkerJobPayload.self)
        } catch {
            return try jsonResponse(
                .badRequest,
                ["status": "error", "message": "Invalid job payload"]
            )
        }

        // Process asynchronously — return 202 Accepted immediately
        Task {
            await workerClient.processJob(
                jobId: payload.jobId,
                fileDownloadUrl: payload.fileDownloadUrl,
                callbackUrl: payload.callbackUrl,
                language: payload.language
            )
        }

        return try jsonResponse(.accepted, ["status": "accepted"])
    }
}

/// Helper to encode a simple dictionary as JSON response.
private func jsonResponse(_ status: HTTPResponseStatus, _ dict: [String: String]) throws -> Response {
    let res = Response(status: status)
    try res.content.encode(dict, as: .json)
    return res
}
