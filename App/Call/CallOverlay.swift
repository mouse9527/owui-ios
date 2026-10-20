import SwiftUI

/// In-app call controls, shown above the chat while a call is running or after it failed.
struct CallOverlay: View {
    let controller: CallController

    var body: some View {
        if controller.isActive, let call = controller.call {
            VStack(spacing: 12) {
                Label(controller.phase.title, systemImage: controller.phase.symbol)
                    .font(.headline)
                    .contentTransition(.symbolEffect(.replace))
                if call.awaitingApproval {
                    Text("请到聊天里确认").font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Button {
                        controller.toggleMute()
                    } label: {
                        Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(call.muted ? "取消静音" : "静音")

                    if controller.phase == .thinking {
                        Button {
                            Task { await controller.stopBackend() }
                        } label: {
                            Image(systemName: "stop.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("停止这次处理")
                    }

                    Button(role: .destructive) {
                        controller.end()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.white)
                            .background(.red, in: Circle())
                    }
                    .accessibilityLabel("结束通话")
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let error = controller.lastError {
            Text(error)
                .font(.footnote)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .transition(.opacity)
        }
    }
}
