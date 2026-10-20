import SwiftUI

@main
struct OWUIApp: App {
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showingSettings = false
    @State private var webPath: String?
    private let calls = CallController.shared

    var body: some View {
        Group {
            if let server = settings.serverURL {
                ChatWebView(
                    server: server,
                    openPath: $webPath,
                    takeOverVoiceButton: settings.takeOverVoiceButton,
                    onToken: { token in settings.updateToken(token, for: server) },
                    onVoiceButton: { request in
                        Task { await calls.beginFromWeb(settings: settings, chatID: request.chatID, models: request.models) }
                    }
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("尚未设置服务器", systemImage: "server.rack")
                } description: {
                    Text("在设置里填写 Open WebUI 的地址。")
                } actions: {
                    Button("打开设置") { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    // Foreground counterpart of the Action button: same start path, so the
                    // Diagnostics section can compare the two.
                    Task { try? await calls.toggle(settings: settings, source: .app) }
                } label: {
                    Image(systemName: calls.isActive ? "phone.down.fill" : "phone.fill")
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel(calls.isActive ? "结束语音通话" : "开始语音通话")
                .disabled(settings.serverURL == nil)

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("设置")
            }
            .padding(.trailing, 12)
            .padding(.top, 4)
        }
        .overlay(alignment: .bottom) {
            CallOverlay(controller: calls)
                .padding(.bottom, 24)
                .animation(.default, value: calls.isActive)
        }
        .onChange(of: calls.isActive) { wasActive, isActive in
            // Show the call's transcript in the web UI once it ends.
            if wasActive, !isActive, let chat = calls.lastChatID { webPath = "c/\(chat)" }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            if settings.serverURL == nil { showingSettings = true }
        }
        .onOpenURL { url in
            #if DEBUG
            // Debug builds only: lets a device test drive a call without touching the phone
            // (`devicectl device process launch --payload-url owui://call/start`).
            Log.call.info("open url \(url.absoluteString, privacy: .public)")
            switch (url.host(), url.path()) {
            case ("call", "/start"):
                // `?hangup=N`: end the call after N seconds, so one launch is enough for a test.
                let hangup = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "hangup" }?.value.flatMap(Double.init)
                Task {
                    try? await calls.begin(settings: settings, source: .app)
                    if let hangup {
                        try? await Task.sleep(for: .seconds(hangup))
                        calls.end()
                    }
                }
            case ("call", "/end"): calls.end()
            default: break
            }
            #endif
        }
    }
}
