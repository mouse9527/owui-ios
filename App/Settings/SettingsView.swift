import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var serverText = ""
    @State private var serverError: String?
    @State private var models: [OWUIModel] = []
    @State private var modelsError: String?
    @State private var loadingModels = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("https://chat.example.com", text: $serverText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(applyServer)
                    if let serverError {
                        Text(serverError).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("服务器")
                } footer: {
                    Text("Open WebUI 的地址。聊天页登录后，语音通话自动使用同一个账号。")
                }

                Section {
                    LabeledContent("聊天页登录") {
                        Text(settings.token == nil ? "未登录" : "已登录")
                            .foregroundStyle(settings.token == nil ? .secondary : .primary)
                    }
                }

                Section {
                    if loadingModels {
                        ProgressView()
                    } else if let modelsError {
                        Text(modelsError).foregroundStyle(.secondary)
                        Button("重试") { Task { await loadModels() } }
                    } else {
                        Picker("默认模型", selection: $settings.defaultModelID) {
                            Text("未选择").tag(String?.none)
                            ForEach(models) { model in
                                Text(model.name).tag(Optional(model.id))
                            }
                        }
                        if let model = models.first(where: { $0.id == settings.defaultModelID }) {
                            LabeledContent("默认工具", value: "\(model.toolIds.count) 个")
                        }
                    }
                } header: {
                    Text("语音通话")
                } footer: {
                    Text("通话中的实质问题交给这个模型处理，使用它在 Open WebUI 里配置的工具。")
                }

                Section {
                    Toggle("接管网页语音按钮", isOn: $settings.takeOverVoiceButton)
                    Picker("委派", selection: $settings.delegationMode) {
                        ForEach(DelegationMode.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("高级")
                } footer: {
                    Text("接管：聊天页输入框旁的「语音模式」按钮改用原生通话（灵动岛、锁屏不断），接在当前聊天、用当前模型；识别不到按钮时保持网页原样。降级模式不连实时通道：网页搜索、记忆等内置工具不可用，只用模型配置的工具。")
                }

                DiagnosticsSection()
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        applyServer()
                        if serverError == nil { dismiss() }
                    }
                }
            }
            .onAppear { serverText = settings.serverURL?.absoluteString ?? "" }
            .task(id: TaskKey(server: settings.serverURL, token: settings.token)) { await loadModels() }
        }
    }

    private struct TaskKey: Equatable {
        let server: URL?
        let token: String?
    }

    private func applyServer() {
        if serverText.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.serverURL = nil
            serverError = nil
            return
        }
        guard let url = ServerAddress.normalize(serverText) else {
            serverError = "地址无效，需要 http(s) 网址。"
            return
        }
        serverError = nil
        serverText = url.absoluteString
        if url != settings.serverURL { settings.serverURL = url }
    }

    private func loadModels() async {
        models = []
        modelsError = nil
        guard let server = settings.serverURL else {
            modelsError = "先填写服务器地址。"
            return
        }
        guard let token = settings.token else {
            modelsError = OWUIError.notSignedIn.errorDescription
            return
        }
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await OWUIClient(server: server, token: token).models()
            if let selected = settings.defaultModelID, !models.contains(where: { $0.id == selected }) {
                settings.defaultModelID = nil
            }
        } catch {
            modelsError = error.localizedDescription
        }
    }
}
