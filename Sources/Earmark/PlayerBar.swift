import SwiftUI
import AudibleKit

/// The transport, pinned under the library while something is loaded.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingChapters = false
    @State private var showingEffects = false
    @State private var scrubbing: TimeInterval?

    private var player: Player { model.player }

    /// The title on screen: the one playing, or the one being prepared.
    private var entry: LibraryEntry? {
        player.entry ?? model.preparingEntry
    }

    /// True while a title has been chosen but no audio is ready.
    private var isPreparing: Bool {
        player.entry == nil && model.preparingEntry != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let override = model.positionOverride {
                undoBar(previous: override.previous)
            }
            HStack(spacing: 16) {
                artwork
                titles
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                speedControl
                effectsButton
                sleepControl
                chapterButton
                stopButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            scrubber
        }
        // Hugs its content. Without this the bar takes the space the library
        // does not use, and the scrubber ends up far below the controls.
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
        .popover(isPresented: $showingChapters) { chapterList }
    }

    // MARK: Pieces

    private var artwork: some View {
        Group {
            if let entry {
                CoverView(entry: entry, size: 44)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .frame(width: 44, height: 44)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry?.book.title ?? "")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                if player.source?.isStream == true {
                    // Streaming is worth showing: seeking outside what has
                    // arrived costs a restart, and nothing is kept on disk.
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// What sits under the title: the state while preparing, the chapter
    /// while playing.
    private var subtitle: String {
        if isPreparing { return "Preparing..." }
        if player.isBuffering { return "Buffering..." }
        return player.currentChapter?.title ?? entry?.book.authorLine ?? ""
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { player.skipBack() } label: {
                Image(systemName: "gobackward.15")
            }
            Button { player.togglePlayPause() } label: {
                if isPreparing || player.isBuffering {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 22)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(isPreparing)
            Button { player.skipAhead() } label: {
                Image(systemName: "goforward.30")
            }
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.end.fill")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .disabled(isPreparing)
    }

    /// Leaves the player, and stops a stream that is still starting.
    private var stopButton: some View {
        Button { model.stopPlayback() } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Stop")
    }

    /// Speed on a slider, because the useful values are between the ones a
    /// menu offers.
    private var speedControl: some View {
        HStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.effects.rate },
                    set: { model.player.effects.rate = $0 }),
                in: AudioEffects.rateRange)
                .frame(width: 96)
                .help("Speed")
            Text(String(format: "%.2f×", player.effects.rate))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
    }

    /// The rest of the sound controls, behind one button.
    private var effectsButton: some View {
        Button { showingEffects = true } label: {
            Image(systemName: player.effects.needsEngine
                  ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
        }
        .buttonStyle(.plain)
        .help("Sound")
        .popover(isPresented: $showingEffects) { EffectsPanel() }
    }

    private var sleepControl: some View {
        Menu {
            Button("End of Chapter") { player.sleepAtEndOfChapter() }
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    player.setSleepTimer(TimeInterval(minutes * 60))
                }
            }
            Divider()
            Button("Off") { player.setSleepTimer(nil) }
        } label: {
            Image(systemName: player.sleepDeadline == nil ? "moon" : "moon.fill")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
    }

    private var chapterButton: some View {
        Button { showingChapters = true } label: {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.plain)
        .disabled(player.entry?.chapters.isEmpty ?? true)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(timeText(scrubbing ?? player.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                // What has arrived, drawn behind the handle. A stream can only
                // move freely inside this part.
                if let buffered = player.bufferedFraction, player.source?.isStream == true {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.tertiary)
                            .frame(width: proxy.size.width * buffered, height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .allowsHitTesting(false)
                }
                Slider(
                    value: Binding(
                        get: { scrubbing ?? player.position },
                        set: { scrubbing = $0 }),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubbing else { return }
                        player.seek(to: target)
                        scrubbing = nil
                    })
                .disabled(isPreparing)
            }
            Text("−" + timeText(max(0, player.duration - (scrubbing ?? player.position))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func undoBar(previous: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
            Text("Moved to where you stopped on another device.")
                .font(.callout)
            Button("Undo") { model.undoPositionOverride() }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary)
    }

    private var chapterList: some View {
        List(player.entry?.chapters ?? [], id: \.start) { chapter in
            Button {
                player.jump(to: chapter)
                showingChapters = false
            } label: {
                HStack {
                    Text(chapter.title).lineLimit(1)
                    Spacer()
                    Text(timeText(chapter.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .fontWeight(chapter.start == player.currentChapter?.start ? .semibold : .regular)
        }
        .frame(width: 340, height: 400)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}
