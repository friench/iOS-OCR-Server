//
//  VaporServerManager.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/21.
//

import SwiftUI
import Combine
import Vision

@MainActor
final class VaporServerManager: ObservableObject {
    private let server = VaporServer()
    private(set) var workerClient = OcrWorkerClient()
    private(set) var sseClient = OcrWorkerSSEClient()
    private var cancellables = Set<AnyCancellable>()
    
    var port: Int = Settings.shared.httpPort

    @Published var status: String = ""
    @Published var networkAddresses: [String: String] = [:]
    @Published var isRestarting = false
    @Published var httpServerEnabled: Bool = Settings.shared.httpServerEnabled

    /// Current worker mode: "sse" or "push"
    var workerMode: String { Settings.shared.workerMode }

    let networkInterfaces = ["en0", "en1", "en2", "en3", "en4", "en5"]

    init() {
        NotificationCenter.default.publisher(for: .vaporServerShouldRestart)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    self.status = String(localized: "server stopped - restarting...")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.startServer()
                }
            }
            .store(in: &cancellables)
        startServer()
    }
    
    func startServer() {
        Task {
            isRestarting = true
            httpServerEnabled = Settings.shared.httpServerEnabled
            let workerEnabled = Settings.shared.workerEnabled
            let mode = Settings.shared.workerMode
            await setupParameters()

            // SSE mode doesn't need Vapor unless HTTP server is enabled
            let pushWorkerNeedsVapor = workerEnabled && mode == "push"
            let needsVapor = httpServerEnabled || pushWorkerNeedsVapor

            if !needsVapor && !workerEnabled {
                status = String(localized: "All services disabled")
                refreshNetworkAddresses()
                isRestarting = false
                return
            }

            if needsVapor {
                await server.setAutoRestart(true)
                
                await server.setOnStopped { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.status = String(localized:"server stopped")
                    }
                }
                
                do {
                    try await server.start()

                    // Register worker route only in push mode
                    if workerEnabled && mode == "push" {
                        if let app = await server.application() {
                            registerWorkerRoute(on: app, workerClient: workerClient)
                        }
                    }

                    if httpServerEnabled {
                        status = String(localized: "server is running")
                    } else {
                        status = String(localized: "worker mode active")
                    }
                    refreshNetworkAddresses()
                } catch {
                    status = String(localized: "unable to start the server")
                }
            } else {
                // SSE-only mode, no Vapor needed
                refreshNetworkAddresses()
            }

            await startWorkerIfNeeded()
            isRestarting = false
        }
    }

    func stopServer() {
        Task {
            isRestarting = true
            await workerClient.stop()
            await sseClient.stop()
            await server.stop()
            status = String(localized: "server stopped")
            isRestarting = false
        }
    }

    func restartServer() {
        status = String(localized: "server restarting...")
        isRestarting = true
        Task {
            await workerClient.stop()
            await sseClient.stop()
            await server.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            startServer()
        }
    }

    /// Call when app returns to foreground to reconnect SSE.
    func handleSceneActive() {
        if Settings.shared.workerEnabled && Settings.shared.workerMode == "sse" {
            sseClient.reconnect()
        }
    }

    private func setupParameters() async {
        port = Settings.shared.httpPort
        
        let level: RecognizeTextRequest.RecognitionLevel =
                (Settings.shared.recognitionLevel == "Fast") ? .fast : .accurate
        
        await server.configure(
            port: port,
            recognitionLevel: level,
            usesLanguageCorrection: Settings.shared.languageCorrection,
            automaticallyDetectsLanguage: Settings.shared.automaticallyDetectsLanguage,
            ocrRoutesEnabled: Settings.shared.httpServerEnabled
        )
    }

    private func startWorkerIfNeeded() async {
        guard Settings.shared.workerEnabled else { return }
        let level: RecognizeTextRequest.RecognitionLevel =
            (Settings.shared.recognitionLevel == "Fast") ? .fast : .accurate

        let mode = Settings.shared.workerMode

        if mode == "sse" {
            sseClient.configure(
                apiHost: Settings.shared.workerApiHost,
                secret: Settings.shared.workerSecret,
                workerName: Settings.shared.workerName,
                recognitionLevel: level,
                usesLanguageCorrection: Settings.shared.languageCorrection,
                automaticallyDetectsLanguage: Settings.shared.automaticallyDetectsLanguage
            )
            await sseClient.start()
        } else {
            // Push mode — needs endpoint
            var endpoint = Settings.shared.workerEndpoint
            if endpoint.isEmpty {
                endpoint = resolveWorkerEndpoint()
                Settings.shared.workerEndpoint = endpoint
            }

            workerClient.configure(
                apiHost: Settings.shared.workerApiHost,
                secret: Settings.shared.workerSecret,
                workerName: Settings.shared.workerName,
                workerEndpoint: endpoint,
                recognitionLevel: level,
                usesLanguageCorrection: Settings.shared.languageCorrection,
                automaticallyDetectsLanguage: Settings.shared.automaticallyDetectsLanguage
            )
            await workerClient.start()
        }
    }

    /// Builds the worker endpoint URL from the first available network address.
    private func resolveWorkerEndpoint() -> String {
        refreshNetworkAddresses()
        if let firstIP = networkAddresses.values.first {
            return "http://\(firstIP):\(port)"
        }
        return ""
    }

    func refreshNetworkAddresses() {
        networkAddresses.removeAll()
        for interface in networkInterfaces {
            if let ip = getIP(for: interface) {
                networkAddresses[interface] = ip
            }
        }
    }

    private func getIP(for interface: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interfaceName = String(cString: ptr.pointee.ifa_name)

            if interfaceName == interface {
                let flags = Int32(ptr.pointee.ifa_flags)
                var addr = ptr.pointee.ifa_addr.pointee

                // Filter out loopback and inactive interfaces
                let isRunning = (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING)
                let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
                if !isRunning || isLoopback {
                    continue
                }

                // IPv4 only
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr,
                                   socklen_t(addr.sa_len),
                                   &hostname,
                                   socklen_t(hostname.count),
                                   nil, 0,
                                   NI_NUMERICHOST) == 0 {
                        return String(cString: hostname)
                    }
                }
            }
        }

        return nil
    }
}
