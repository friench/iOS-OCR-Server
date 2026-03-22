//
//  Settings.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/8.
//

import Foundation
import Vision

class Settings {
    static let shared = Settings()
    
    private init() {
        
    }
    
    var httpPort: Int {
        get {
            return UserDefaults.standard.object(forKey: "httpPort") as? Int ?? 8000
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "httpPort")
        }
    }
    
    var recognitionLevel: String {
        get {
            return UserDefaults.standard.string(forKey: "recognitionLevel") ?? "Accurate"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "recognitionLevel")
        }
    }
    
    var languageCorrection: Bool {
        get {
            return UserDefaults.standard.object(forKey: "languageCorrection") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "languageCorrection")
        }
    }
    
    var automaticallyDetectsLanguage: Bool {
        get {
            return UserDefaults.standard.object(forKey: "automaticallyDetectsLanguage") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "automaticallyDetectsLanguage")
        }
    }

    // MARK: - Job Queue

    var jobQueueEnabled: Bool {
        get {
            return UserDefaults.standard.object(forKey: "jobQueueEnabled") as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "jobQueueEnabled")
        }
    }

    var jobQueueHost: String {
        get {
            return UserDefaults.standard.string(forKey: "jobQueueHost") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "jobQueueHost")
        }
    }

    var jobQueueApiKey: String {
        get {
            return UserDefaults.standard.string(forKey: "jobQueueApiKey") ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "jobQueueApiKey")
        }
    }
}
