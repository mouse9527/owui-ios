import AppIntents

// Compiled into both targets so Live Activity buttons can reference the intents; `perform()` always
// runs in the app process (LiveActivityIntent / AudioRecordingIntent), where `CallControls` exists.
// The widget extension gets the no-op shim at the bottom of this file.

/// Action button / Shortcuts entry. Starts a call in the background without opening the app;
/// pressing it again during a call hangs up.
struct StartCallIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "语音通话"
    static let description = IntentDescription("开始或结束与 Open WebUI 的语音通话，不切换到 App。")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult {
        try await CallControls.toggle()
        return .result()
    }
}

struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束语音通话"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        CallControls.end()
        return .result()
    }
}

struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "语音通话静音"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        CallControls.toggleMute()
        return .result()
    }
}

#if WIDGET_EXTENSION
/// The extension only renders buttons; the system runs these intents in the app.
@MainActor
enum CallControls {
    static func toggle() async throws {}
    static func end() {}
    static func toggleMute() {}
}
#endif
