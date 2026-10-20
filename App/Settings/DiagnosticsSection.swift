import ActivityKit
import SwiftUI

/// Settings → 诊断: Live Activity state and recent call / activity events, so a device test can
/// tell "the activity was refused" from "the activity exists but is not shown".
struct DiagnosticsSection: View {
    private let diagnostics = Diagnostics.shared
    @State private var summary = ""
    @State private var testActivityID: String?

    var body: some View {
        Section {
            LabeledContent("实时活动") {
                Text(summary).font(.caption).multilineTextAlignment(.trailing)
            }
            if let error = diagnostics.lastActivityError {
                LabeledContent("最近一次活动错误") {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                }
            }
            Button(testActivityID == nil ? "单独测试实时活动（不录音）" : "结束测试活动") {
                Task {
                    await toggleTestActivity()
                    refresh()
                }
            }
            Button("刷新") { refresh() }
            ForEach(diagnostics.entries.prefix(20)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.category)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.message).font(.caption)
                        .foregroundStyle(entry.isError ? .red : .primary)
                }
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("「单独测试」只请求一个实时活动、不开麦克风：它能显示，说明实时活动本身没问题，问题在后台启动。Mac 上也可以在「控制台」里按 subsystem 过滤看日志。")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        summary = diagnostics.activitySummary
    }

    private func toggleTestActivity() async {
        if let id = testActivityID {
            for activity in Activity<CallActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            testActivityID = nil
            diagnostics.record("activity", "已结束测试活动")
            return
        }
        let state = CallActivityAttributes.ContentState(phase: .listening, muted: false, detail: "测试活动（未录音）", modelName: "")
        do {
            let activity = try Activity.request(attributes: CallActivityAttributes(), content: .init(state: state, staleDate: nil))
            testActivityID = activity.id
            Log.activity.info("test activity ok id=\(activity.id, privacy: .public)")
            diagnostics.record("activity", "测试活动已请求，状态 \(activity.activityState)")
        } catch {
            let message = describeActivityError(error)
            Log.activity.error("test activity failed: \(message, privacy: .public)")
            diagnostics.record("activity", "测试活动请求失败：\(message)", error: true)
        }
    }
}
