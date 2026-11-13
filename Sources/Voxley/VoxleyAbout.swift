import AppKit
import SwiftUI

@MainActor
final class AboutWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 510, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "About Voxley"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: VoxleyAbout())
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct VoxleyAbout: View {
    private static let website = URL(string: "https://voxley.si/")!
    private static let tipPage = URL(string: "https://buymeacoffee.com/protomotalab")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var appIcon: NSImage {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: appIcon)
                        .resizable().scaledToFit().frame(width: 62, height: 62)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voxley").font(.largeTitle.weight(.semibold))
                        Text("Version \(version) · Made by Protomota")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Private dictation for Mac. Speak wherever you type, with transcription on your device.")
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Every feature is free. If Voxley helps you and you’re able to contribute, an optional tip helps support its development.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Link(destination: Self.tipPage) {
                                Label("Buy me a coffee", systemImage: "cup.and.saucer")
                            }
                            .buttonStyle(.borderedProminent)
                            ShareLink(item: Self.website, subject: Text("Voxley for Mac"),
                                      message: Text("Free, private dictation for Mac.")) {
                                Label("Share Voxley", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Label("Free, supported by tips", systemImage: "heart")
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Follow Voxley").font(.headline)
                    HStack(spacing: 12) {
                        Link(destination: Self.website) {
                            Label("Website", systemImage: "globe")
                        }
                        Link(destination: URL(string: "https://newsletter.protomota.com/")!) {
                            Label("Protomota newsletter", systemImage: "envelope")
                        }
                        Link(destination: URL(string: "https://x.com/ProtomotaLab")!) {
                            Label("Follow on X", systemImage: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text("© 2026 Protomota, LLC").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
