import AppIntents

/// App-side implementation behind the intents in `Shared/CallIntents.swift`.
@MainActor
enum CallControls {
    /// Returns as soon as recording and the Live Activity have started; the call runs on in the app.
    static func toggle() async throws {
        let started = Date()
        Log.intent.info("StartCallIntent perform begin")
        defer {
            Log.intent.info("StartCallIntent perform returned after \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        }
        do {
            try await CallController.shared.toggle(settings: .shared, source: .intent)
        } catch {
            // Report the reason to Shortcuts / the Action button instead of a generic failure.
            Log.intent.error("StartCallIntent failed: \(error.localizedDescription, privacy: .public)")
            throw CallIntentError(message: error.localizedDescription)
        }
    }

    static func end() {
        Log.intent.info("EndCallIntent")
        CallController.shared.end()
    }

    static func toggleMute() {
        Log.intent.info("ToggleMuteIntent")
        CallController.shared.toggleMute()
    }
}

struct CallIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct OWUIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCallIntent(),
            phrases: ["用 \(.applicationName) 语音通话", "\(.applicationName) 语音通话"],
            shortTitle: "语音通话",
            systemImageName: "phone.fill"
        )
    }
}
