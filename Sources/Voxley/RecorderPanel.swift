import AppKit
import SwiftUI

@MainActor
final class RecorderPanel {
    private var panel: NonactivatingRecorder?
    private let size = NSSize(width: 386, height: 141)

    func connect(_ controller: DictationController) {
        withObservationTracking {
            if controller.phase != .idle {
                show(controller)
            } else {
                panel?.orderOut(nil)
            }
        } onChange: { [weak self, weak controller] in
            Task { @MainActor in
                if let controller { self?.connect(controller) }
            }
        }
    }

    private func show(_ controller: DictationController) {
        let panel = panel ?? makePanel(controller)
        guard !panel.isVisible else { return }
        let anchor = controller.recordingWindow
        let referencePoint = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(referencePoint) }) ?? NSScreen.main
        else { return }

        let visible = screen.visibleFrame
        let width = min(size.width, visible.width - 24)
        let left = visible.midX - width / 2
        let bottom = visible.minY + 24
        panel.setFrame(NSRect(x: left, y: bottom, width: width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel(_ controller: DictationController) -> NonactivatingRecorder {
        let panel = NonactivatingRecorder(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voxley Recorder"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = RecorderHostingView(rootView: RecorderView(controller: controller))
        self.panel = panel
        return panel
    }
}

private final class NonactivatingRecorder: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecorderHostingView: NSHostingView<RecorderView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecorderView: View {
    let controller: DictationController
    private var recording: Bool { controller.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RecorderTranscript(text: controller.liveText, status: controller.phase.title)

            HStack(spacing: 10) {
                if recording {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.white)
                        .accessibilityLabel("Microphone recording")
                    RecorderWave(frame: controller.waveform)
                        .frame(maxWidth: 220)
                        .frame(height: 60)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.5),
                                .init(color: .clear, location: 1),
                            ], startPoint: .leading, endPoint: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Button {
                        controller.stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Stop recording")
                    .help("Stop recording and paste the transcript")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Spacer()
                }
            }
            .frame(height: 62)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 17)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 17).fill(.black.opacity(0.26))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .strokeBorder(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(2)
        .environment(\.colorScheme, .dark)
    }
}
