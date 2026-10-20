import ActivityKit
import Foundation
import Observation
import os

/// Unified logging. Filter in Console.app (or `log stream`) by subsystem = the app's bundle ID.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "owui"
    static let activity = Logger(subsystem: subsystem, category: "activity")
    static let intent = Logger(subsystem: subsystem, category: "intent")
    static let call = Logger(subsystem: subsystem, category: "call")
}

/// What the Settings 诊断 section shows: recent events with their outcome, newest first.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let category: String
        let message: String
        let isError: Bool
    }

    private(set) var entries: [Entry] = []
    private(set) var lastActivityError: String?

    func record(_ category: String, _ message: String, error: Bool = false) {
        entries.insert(Entry(category: category, message: message, isError: error), at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        if error, category == "activity" { lastActivityError = message }
    }

    /// Live state of ActivityKit, read on demand.
    var activitySummary: String {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let activities = Activity<CallActivityAttributes>.activities
        let states = activities.map { "\($0.activityState)" }.joined(separator: ", ")
        return "areActivitiesEnabled=\(enabled)，activities=\(activities.count)" + (states.isEmpty ? "" : "（\(states)）")
    }
}

/// `ActivityAuthorizationError` cases with what each usually means here.
func describeActivityError(_ error: Error) -> String {
    guard let error = error as? ActivityAuthorizationError else { return "\(error)" }
    let hint: String = switch error {
    case .visibility: "App 不在前台，系统不允许此时启动"
    case .denied: "用户关闭了实时活动"
    case .unsupported: "设备不支持"
    case .unentitled: "缺少权限（Info.plist NSSupportsLiveActivities）"
    case .globalMaximumExceeded, .targetMaximumExceeded: "同时存在的活动太多"
    case .attributesTooLarge: "数据过大"
    default: ""
    }
    return "ActivityAuthorizationError.\(error)" + (hint.isEmpty ? "" : "：\(hint)")
}
