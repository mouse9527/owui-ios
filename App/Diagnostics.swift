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

    struct Entry: Identifiable, Codable {
        var id = UUID()
        var date = Date()
        let category: String
        let message: String
        let isError: Bool
        /// Read back from disk: written by an earlier run (possibly one that crashed).
        var previousRun = false
    }

    private(set) var entries: [Entry] = []
    private(set) var lastActivityError: String?

    /// Each entry is also appended to a file right away, so what happened just before a crash
    /// (e.g. an Action-button start in the background) is visible after relaunch.
    private let file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appending(path: "diagnostics.jsonl")

    private init() {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        entries = text.split(separator: "\n").suffix(50).reversed().compactMap {
            var entry = try? decoder.decode(Entry.self, from: Data($0.utf8))
            entry?.previousRun = true
            return entry
        }
        lastActivityError = entries.first { $0.isError && $0.category == "activity" }?.message
    }

    func record(_ category: String, _ message: String, error: Bool = false) {
        let entry = Entry(category: category, message: message, isError: error)
        entries.insert(entry, at: 0)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        if error, category == "activity" { lastActivityError = message }
        append(entry)
    }

    func clear() {
        entries.removeAll()
        lastActivityError = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func append(_ entry: Entry) {
        guard let file, var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path) {
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        // Keep the file small: rewrite the last 200 lines once it passes ~64 KB.
        if let size = try? handle.offset(), size > 64_000,
           let text = try? String(contentsOf: file, encoding: .utf8) {
            let kept = text.split(separator: "\n").suffix(200).joined(separator: "\n") + "\n"
            try? kept.write(to: file, atomically: true, encoding: .utf8)
        }
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
