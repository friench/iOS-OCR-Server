//
//  SettingsView.swift
//  OcrServer
//
//  Created by Riddle Ling on 2025/8/8.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverManager: VaporServerManager
    @Environment(\.dismiss) private var dismiss
    @State var recognitionLevel = Settings.shared.recognitionLevel
    @State var languageCorrection = Settings.shared.languageCorrection
    @State var autoDetectLanguage = Settings.shared.automaticallyDetectsLanguage
    @State var httpPort: String = String(Settings.shared.httpPort)
    @State private var showingPortSheet = false
    @State private var inputPortText: String = String(Settings.shared.httpPort)

    // HTTP Server
    @State private var httpServerEnabled = Settings.shared.httpServerEnabled

    // OCR Worker
    @State private var workerEnabled = Settings.shared.workerEnabled
    @State private var workerMode = Settings.shared.workerMode
    @State private var workerName = Settings.shared.workerName
    @State private var workerApiHost = Settings.shared.workerApiHost
    @State private var workerSecret = Settings.shared.workerSecret
    @State private var workerEndpoint = Settings.shared.workerEndpoint
    @State private var showingWorkerApiHostSheet = false
    @State private var showingWorkerSecretSheet = false
    @State private var showingWorkerNameSheet = false
    @State private var showingWorkerEndpointSheet = false
    @State private var inputWorkerApiHostText = Settings.shared.workerApiHost
    @State private var inputWorkerSecretText = Settings.shared.workerSecret
    @State private var inputWorkerNameText = Settings.shared.workerName
    @State private var inputWorkerEndpointText = Settings.shared.workerEndpoint
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List {
                    Section("Text Recognition") {
                        ZStack {
                            SettingsRow(icon: "text.viewfinder",
                                        title: String(localized:"Recognition Level"),
                                        value: $recognitionLevel)
                            NavigationLink(destination: RecognitionLevelView(recognitionLevel: $recognitionLevel)) {
                                EmptyView()
                            }
                            .opacity(0)
                        }
                        SettingsRow2(icon: "text.badge.checkmark",
                                     title: String(localized:"Language Correction"),
                                     isOn: $languageCorrection)
                        SettingsRow2(icon: "globe",
                                     title: String(localized:"Auto Detects Language"),
                                     isOn: $autoDetectLanguage)
                    }
                    Section("Server") {
                        SettingsRow2(icon: "power",
                                     title: String(localized: "Enable HTTP Server"),
                                     isOn: $httpServerEnabled)
                        if httpServerEnabled {
                            SettingsRow(icon: "server.rack", title: "HTTP Port", value: $httpPort)
                                .onTapGesture {
                                    showingPortSheet = true
                                }
                        }
                    }

                    Section(String(localized: "OCR Worker")) {
                        SettingsRow2(icon: "arrow.triangle.2.circlepath",
                                     title: String(localized: "Enable Worker"),
                                     isOn: $workerEnabled)
                        if workerEnabled {
                            Picker(selection: $workerMode) {
                                Text("SSE").tag("sse")
                                Text("Push").tag("push")
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 28, height: 28)
                                    Text(String(localized: "Mode"))
                                        .font(.body)
                                        .fontWeight(.medium)
                                }
                            }
                            .pickerStyle(.menu)
                            SettingsRow(icon: "network",
                                        title: String(localized: "API Host"),
                                        value: $workerApiHost)
                                .onTapGesture { showingWorkerApiHostSheet = true }
                            SettingsRow(icon: "person",
                                        title: String(localized: "Worker Name"),
                                        value: $workerName)
                                .onTapGesture { showingWorkerNameSheet = true }
                            if workerMode == "push" {
                                SettingsRow(icon: "link",
                                            title: String(localized: "Endpoint"),
                                            value: $workerEndpoint)
                                    .onTapGesture { showingWorkerEndpointSheet = true }
                            }
                            SettingsRow(icon: "key",
                                        title: String(localized: "Secret"),
                                        value: $workerSecret,
                                        masked: true)
                                .onTapGesture { showingWorkerSecretSheet = true }
                        }
                    }
                    
                    Button(action: apply) {
                        HStack(spacing: 8) {
                            if serverManager.isRestarting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text("Apply & Restart server")
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(serverManager.isRestarting ? Color.gray : Color(hex: "EA7500"))
                        .cornerRadius(8)
                    }
                    .listRowInsets(EdgeInsets()) // 移除預設的邊距
                    .buttonStyle(PlainButtonStyle()) // 移除按鈕的預設樣式
                    .disabled(serverManager.isRestarting)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.primary)
                    }
                }
            }
            .onChange(of: languageCorrection) { oldValue, newValue in
                Settings.shared.languageCorrection = newValue
            }
            .onChange(of: autoDetectLanguage) { oldValue, newValue in
                Settings.shared.automaticallyDetectsLanguage = newValue
            }
            .onChange(of: workerEnabled) { oldValue, newValue in
                Settings.shared.workerEnabled = newValue
            }
            .onChange(of: workerMode) { oldValue, newValue in
                Settings.shared.workerMode = newValue
            }
            .onChange(of: httpServerEnabled) { oldValue, newValue in
                Settings.shared.httpServerEnabled = newValue
            }
            .sheet(isPresented: $showingPortSheet) {
                VStack {
                    HStack {
                        Text("Set HTTP Port: ")
                            .padding(.trailing, 8)
                        TextField("HTTP Port", text: $inputPortText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                        .frame(height: 40)
                    HStack {
                        Button("Cancel") { showingPortSheet = false }
                            .fontWeight(.medium)
                        Spacer()
                        Button("Confirm") {
                            Settings.shared.httpPort = Int(inputPortText) ?? 8000
                            httpPort = inputPortText
                            showingPortSheet = false
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showingWorkerApiHostSheet) {
                VStack {
                    HStack {
                        Text(String(localized: "API Host:"))
                            .padding(.trailing, 8)
                        TextField("https://api.example.com", text: $inputWorkerApiHostText)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                        .frame(height: 40)
                    HStack {
                        Button("Cancel") { showingWorkerApiHostSheet = false }
                            .fontWeight(.medium)
                        Spacer()
                        Button("Confirm") {
                            Settings.shared.workerApiHost = inputWorkerApiHostText
                            workerApiHost = inputWorkerApiHostText
                            showingWorkerApiHostSheet = false
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showingWorkerNameSheet) {
                VStack {
                    HStack {
                        Text(String(localized: "Worker Name:"))
                            .padding(.trailing, 8)
                        TextField("ocr-worker-ios", text: $inputWorkerNameText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                        .frame(height: 40)
                    HStack {
                        Button("Cancel") { showingWorkerNameSheet = false }
                            .fontWeight(.medium)
                        Spacer()
                        Button("Confirm") {
                            Settings.shared.workerName = inputWorkerNameText
                            workerName = inputWorkerNameText
                            showingWorkerNameSheet = false
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(200)])
            }
            .sheet(isPresented: $showingWorkerEndpointSheet) {
                VStack {
                    HStack {
                        Text(String(localized: "Endpoint:"))
                            .padding(.trailing, 8)
                        TextField("http://192.168.1.x:8000", text: $inputWorkerEndpointText)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(String(localized: "Leave empty for auto-detection"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                        .frame(height: 20)
                    HStack {
                        Button("Cancel") { showingWorkerEndpointSheet = false }
                            .fontWeight(.medium)
                        Spacer()
                        Button("Confirm") {
                            Settings.shared.workerEndpoint = inputWorkerEndpointText
                            workerEndpoint = inputWorkerEndpointText
                            showingWorkerEndpointSheet = false
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(220)])
            }
            .sheet(isPresented: $showingWorkerSecretSheet) {
                VStack {
                    HStack {
                        Text(String(localized: "Secret:"))
                            .padding(.trailing, 8)
                        TextField(String(localized: "Shared secret"), text: $inputWorkerSecretText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                        .frame(height: 40)
                    HStack {
                        Button("Cancel") { showingWorkerSecretSheet = false }
                            .fontWeight(.medium)
                        Spacer()
                        Button("Confirm") {
                            Settings.shared.workerSecret = inputWorkerSecretText
                            workerSecret = inputWorkerSecretText
                            showingWorkerSecretSheet = false
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(200)])
            }
        }
    }
    
    private func apply() {
        serverManager.restartServer()
    }
    
    
}
    
struct SettingsRow: View {
    let icon: String
    let title: String
    @Binding var value: String
    var masked: Bool = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 圖示
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
            
            // 文字內容
            Text(title)
                .font(.body)
                .fontWeight(.medium)
        
            Spacer()
            
            Text(displayValue)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // 箭頭指示
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    private var displayValue: String {
        if masked {
            return value.isEmpty ? String(localized: "Not set") : String(repeating: "•", count: min(value.count, 8))
        }
        return getValueString(value)
    }
    
    private func getValueString(_ level: String) -> String {
        switch level {
        case "Accurate":
            return String(localized:"Accurate")
        case "Fast":
            return String(localized:"Fast")
        default:
            return level.isEmpty ? String(localized: "Not set") : level
        }
    }
}

struct SettingsRow2: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // 圖示
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
            
            // 文字內容
            Text(title)
                .font(.body)
                .fontWeight(.medium)
            
            Spacer()
            
            Toggle("", isOn: $isOn)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
