import SwiftUI

/// Transport controls: start/pause, reset and speed in real-time mode;
/// play/pause and a scrubbable timeline when replaying an offline run.
struct PlaybackBar: View {
    @ObservedObject var controller: SimulationController

    var body: some View {
        if controller.isOfflinePlayback, let run = controller.offlineRun {
            offlineControls(run)
        } else {
            realtimeControls
        }
    }

    private var realtimeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    controller.isRunning.toggle()
                } label: {
                    Label(controller.isRunning ? "일시정지" : "시작",
                          systemImage: controller.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    controller.reset()
                } label: {
                    Label("리셋", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
                Text(String(format: "t = %.1f s", controller.simTime))
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("속도 \(String(format: "%.2gx", controller.speed))")
                    .frame(width: 90, alignment: .leading)
                Slider(value: $controller.speed, in: 0.25...4, step: 0.25)
            }
        }
    }

    private func offlineControls(_ run: OfflineRun) -> some View {
        let lastIndex = max(0, run.frames.count - 1)
        let current = run.frames[safe: controller.offlineFrameIndex]?.time ?? 0
        let end = run.frames.last?.time ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    controller.toggleOfflinePlayback()
                } label: {
                    Label(controller.isOfflinePlaying ? "일시정지" : "재생",
                          systemImage: controller.isOfflinePlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    controller.exitOfflinePlayback()
                } label: {
                    Label("실시간으로", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
                Text(String(format: "%.1f / %.0f s", current, end))
                    .font(.system(.body, design: .monospaced))
            }
            Slider(value: Binding(get: { Double(controller.offlineFrameIndex) },
                                  set: { controller.offlineFrameIndex = Int($0.rounded()) }),
                   in: 0...Double(max(1, lastIndex)), step: 1) { editing in
                if editing { controller.stopOfflinePlayback() }
            }
            .disabled(lastIndex == 0)
        }
    }
}
