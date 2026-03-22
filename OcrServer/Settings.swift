//
//  Settings.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/8.
//

import Foundation
import Vision

final class Settings: Sendable {
    static let shared = Settings()
    
    private init() {}
    
    var httpPort: Int {
        get { UserDefaults.standard.object(forKey: "httpPort") as? Int ?? 8000 }
        set { UserDefaults.standard.set(newValue, forKey: "httpPort") }
    }
    
    var recognitionLevel: String {
        get { UserDefaults.standard.string(forKey: "recognitionLevel") ?? "Accurate" }
        set { UserDefaults.standard.set(newValue, forKey: "recognitionLevel") }
    }
    
    var languageCorrection: Bool {
        get { UserDefaults.standard.object(forKey: "languageCorrection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "languageCorrection") }
    }
    
    var automaticallyDetectsLanguage: Bool {
        get { UserDefaults.standard.object(forKey: "automaticallyDetectsLanguage") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticallyDetectsLanguage") }
    }

    // MARK: - HTTP Server

    var httpServerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "httpServerEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "httpServerEnabled") }
    }

    // MARK: - OCR Worker

    /// Worker mode: "sse" (pull via Server-Sent Events) or "push" (server pushes to endpoint).
    var workerMode: String {
        get { UserDefaults.standard.string(forKey: "workerMode") ?? "sse" }
        set { UserDefaults.standard.set(newValue, forKey: "workerMode") }
    }

    var workerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "workerEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "workerEnabled") }
    }

    var workerName: String {
        get { UserDefaults.standard.string(forKey: "workerName") ?? "ocr-worker-ios" }
        set { UserDefaults.standard.set(newValue, forKey: "workerName") }
    }

    var workerApiHost: String {
        get { UserDefaults.standard.string(forKey: "workerApiHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "workerApiHost") }
    }

    var workerSecret: String {
        get { UserDefaults.standard.string(forKey: "workerSecret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "workerSecret") }
    }

    var workerEndpoint: String {
        get { UserDefaults.standard.string(forKey: "workerEndpoint") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "workerEndpoint") }
    }
}
