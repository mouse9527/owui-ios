import AppIntents

/// App-side implementation behind the intents in `Shared/CallIntents.swift`.
@MainActor
enum CallControls {
    static func toggle() async throws {
        let controller = CallController.shared
        if controller.isActive {
            controller.end()
            return
        }
        await controller.start(settings: .shared)
        // Report a failure to Shortcuts / the Action button instead of ending silently.
        if !controller.isActive, let error = controller.lastError { throw CallIntentError(message: error) }
    }

    static func end() {
        CallController.shared.end()
    }

    static func toggleMute() {
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
