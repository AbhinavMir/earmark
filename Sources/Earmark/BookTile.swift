import SwiftUI

/// One cover in the grid, with its download state and listening progress.
struct BookTile: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let isSelected: Bool
    var onToggleSelection: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            Text(entry.book.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.book.authorLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: entry.book.coverURL) { image in
                image.resizable().aspectRatio(1, contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 3, y: 2)

            badge.padding(6)
        }
        .overlay(alignment: .bottom) { progressBar }
        .overlay { playOverlay }
        .onHover { isHovering = $0 }
    }

    /// Two large controls over the cover while the pointer is on it: play,
    /// and everything else. Both are big enough to hit without aiming.
    @ViewBuilder
    private var playOverlay: some View {
        if isHovering || isCurrent {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(isHovering ? 0.42 : 0.18))

                if isHovering {
                    HStack(spacing: 18) {
                        Button {
                            Task { await model.play(entry) }
                        } label: {
                            Image(systemName: playSymbol)
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                                .shadow(radius: 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing)
                        .help(entry.isDownloaded ? "Play" : "Stream")

                        Menu {
                            moreActions
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white)
                                .shadow(radius: 5)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 44, height: 44)
                        .help("More")
                    }
                } else {
                    // Playing but not hovered: say so without hiding the cover.
                    Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
        }
    }

    /// What the second control offers.
    @ViewBuilder
    private var moreActions: some View {
        Button(entry.isDownloaded ? "Play" : "Stream") {
            Task { await model.play(entry) }
        }
        Divider()
        if entry.isDownloaded {
            Button("Show in Finder") { model.revealInFinder(entry) }
            Button("Remove Download") { Task { await model.removeDownload(entry) } }
        } else if model.queue.isQueued(entry.id) {
            Button("Cancel Download") { model.queue.cancel(entry.id) }
        } else {
            Button("Download") { model.download([entry]) }
        }
        Divider()
        Button(isSelected ? "Deselect" : "Select") { onToggleSelection() }
        if !entry.bookmarks.isEmpty {
            Divider()
            Text("\(entry.bookmarks.count) bookmarks")
        }
    }

    /// True when this title is the one loaded or being prepared.
    private var isCurrent: Bool {
        model.player.entry?.id == entry.id || model.preparingEntry?.id == entry.id
    }

    private var isPreparing: Bool {
        model.preparingEntry?.id == entry.id
    }

    private var playSymbol: String {
        if isPreparing { return "hourglass" }
        if isCurrent, model.player.isPlaying { return "pause.circle.fill" }
        return "play.circle.fill"
    }

    @ViewBuilder
    private var badge: some View {
        if let job = model.queue.jobs.first(where: { $0.asin == entry.id && $0.state.isActive }) {
            Image(systemName: job.state == .decrypting ? "gearshape" : "arrow.down.circle.fill")
                .symbolEffect(.pulse)
                .foregroundStyle(.white, .blue)
                .background(Circle().fill(.black.opacity(0.4)))
        } else if entry.isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = entry.progress, progress > 0.001, !entry.isFinished {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.35))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }
}
