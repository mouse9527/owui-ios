import ActivityKit
import Foundation

/// Shared between the app (starts / updates the activity) and the widget extension (renders it).
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: CallPhase
        var muted: Bool
        /// Short status line, e.g. the last error. Never the transcript.
        var detail: String?
    }

    var modelName: String
}

enum CallPhase: String, Codable, Hashable {
    case connecting
    case listening
    case thinking
    case speaking
    case failed

    var title: String {
        switch self {
        case .connecting: "连接中"
        case .listening: "在听"
        case .thinking: "在想"
        case .speaking: "在说"
        case .failed: "出错"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
