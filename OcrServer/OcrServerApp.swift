//
//  OcrServerApp.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/1.
//

import SwiftUI

@main
struct OcrServerApp: App {
    @StateObject private var serverManager = VaporServerManager()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                serverManager: serverManager
            )
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                serverManager.handleSceneActive()
            }
        }
    }
}
