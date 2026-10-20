import SwiftUI

@main
struct OWUIApp: App {
    @State private var settings = AppSettings()

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

    var body: some View {
        Group {
            if let server = settings.serverURL {
                ChatWebView(server: server) { token in
                    settings.updateToken(token, for: server)
                }
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
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .padding(.trailing, 12)
            .padding(.top, 4)
            .accessibilityLabel("设置")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            if settings.serverURL == nil { showingSettings = true }
        }
    }
}
