import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OWUIWidgetBundle: WidgetBundle {
    var body: some Widget {
        CallLiveActivity()
    }
}

// Step 1 skeleton: status only. Step 3 adds the expanded layout and end / mute / open buttons.
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            HStack {
                Image(systemName: context.state.phase.symbol)
                Text(context.state.phase.title).font(.headline)
                Spacer()
                Text(context.attributes.modelName).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Label(context.state.phase.title, systemImage: context.state.phase.symbol)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
            } compactTrailing: {
                Text(context.state.phase.title).font(.caption2)
            } minimal: {
                Image(systemName: context.state.phase.symbol)
            }
        }
    }
}
