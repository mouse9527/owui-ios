import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OWUIWidgetBundle: WidgetBundle {
    var body: some Widget {
        CallLiveActivity()
    }
}

/// Opens the app; the app delegate needs no handling, launching is enough.
private let openAppURL = URL(string: "owui://call")!

struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .widgetURL(openAppURL)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.phase.title).font(.headline)
                        Text(state.detail ?? state.modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallButtons(state: state)
                }
            } compactLeading: {
                PhaseIcon(phase: state.phase)
            } compactTrailing: {
                Text(state.phase.title).font(.caption2)
            } minimal: {
                PhaseIcon(phase: state.phase)
            }
            .widgetURL(openAppURL)
            .keylineTint(phaseColor(state.phase))
        }
    }
}

private struct LockScreenView: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                PhaseIcon(phase: state.phase).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.phase.title).font(.headline)
                    Text(state.detail ?? state.modelName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.muted {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.secondary)
                }
            }
            if state.phase != .failed {
                CallButtons(state: state)
            }
        }
        .padding()
    }
}

private struct CallButtons: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: ToggleMuteIntent()) {
                Label(state.muted ? "取消静音" : "静音", systemImage: state.muted ? "mic.slash.fill" : "mic.fill")
            }
            Link(destination: openAppURL) {
                Label("打开", systemImage: "arrow.up.forward.app")
            }
            Button(intent: EndCallIntent()) {
                Label("结束", systemImage: "phone.down.fill")
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .font(.title3)
    }
}

private struct PhaseIcon: View {
    let phase: CallPhase

    var body: some View {
        Image(systemName: phase.symbol)
            .foregroundStyle(phaseColor(phase))
            .symbolEffect(.variableColor.iterative, isActive: phase == .listening || phase == .speaking)
            .symbolEffect(.pulse, isActive: phase == .thinking || phase == .connecting)
    }
}

private func phaseColor(_ phase: CallPhase) -> Color {
    switch phase {
    case .connecting: .gray
    case .listening: .green
    case .thinking: .orange
    case .speaking: .blue
    case .failed: .red
    }
}
