import SwiftUI
import AppKit

/// A small always-visible player, for when the library is not needed.
///
/// It is a separate window rather than a shrunken main window, so the library
/// keeps its size and place while the small one floats above other work.
@MainActor
final class MiniPlayerWindow {
    static let shared = MiniPlayerWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 132),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false)
        panel.title = "Now Playing"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(
            rootView: MiniPlayerView().environment(model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        window = panel
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }
    }

    func close() {
        window?.close()
        window = nil
    }
}

/// The small player's contents: cover, title, transport, and a scrubber.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model

    private var player: Player { model.player }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if let entry = player.entry {
                    CoverView(entry: entry, size: 46)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.entry?.book.title ?? "Nothing playing")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(player.currentChapter?.title
                         ?? player.entry?.book.authorLine ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 16) {
                Button { player.skipBack() } label: { Image(systemName: "gobackward.15") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                Button { player.skipAhead() } label: { Image(systemName: "goforward.30") }
                Spacer()
                Text(String(format: "%.2f×", player.effects.rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(MiniPlayerView.clock(player.position))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { player.position },
                        set: { player.seek(to: $0) }),
                    in: SafeTime.sliderRange(player.duration))
                Text("−" + MiniPlayerView.clock(max(0, player.duration - player.position)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        SafeTime.clock(seconds)
    }
}
