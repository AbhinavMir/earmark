import SwiftUI
import AudibleKit

/// One title as a row, for the list layout.
///
/// A row shows what a cover cannot: length, series position, and how far the
/// listener has gone, all readable at a glance down the column.
struct BookRow: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }))
                .labelsHidden()
                .toggleStyle(.checkbox)

            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.book.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.book.authorLine.isEmpty
                         ? "Unknown author" : entry.book.authorLine)
                    if let series = entry.book.series {
                        Text("·")
                        Text(series.position.map { "\(series.name) \($0)" } ?? series.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            statusColumn
            lengthColumn
            actions
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground))
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
    }

    var onToggleSelection: () -> Void = {}

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isCurrent { return Color.accentColor.opacity(0.08) }
        return isHovering ? Color.primary.opacity(0.05) : .clear
    }

    private var cover: some View {
        CoverView(entry: entry, size: 40)
    }

    /// Where the listener is, or what the queue is doing with this title.
    @ViewBuilder
    private var statusColumn: some View {
        if let job = model.queue.activeByASIN[entry.id] {
            Text(job.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        } else if entry.isFinished {
            Label("Finished", systemImage: "checkmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .frame(width: 130, alignment: .trailing)
        } else if let progress = entry.progress, progress > 0.001 {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 52)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(entry.percentText ?? "")
                        .font(.caption.monospacedDigit())
                    if let left = entry.remainingText {
                        Text("\(left) left")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .trailing)
        } else {
            Color.clear.frame(width: 130, height: 1)
        }
    }

    private var lengthColumn: some View {
        Text(entry.book.duration.map(BookRow.hoursAndMinutes) ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .trailing)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                // Pauses the title that is already playing rather than
                // starting it again from its stored place.
                if isCurrent, model.player.entry != nil {
                    model.player.togglePlayPause()
                } else {
                    Task { await model.play(entry) }
                }
            } label: {
                Image(systemName: playSymbol)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isDownloaded ? "Play" : "Stream")

            if entry.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .help("Downloaded")
            } else {
                Button { model.download([entry]) } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Download")
                .disabled(model.queue.isQueued(entry.id))
            }
        }
        .frame(width: 56, alignment: .trailing)
    }

    private var isCurrent: Bool {
        model.player.entry?.id == entry.id || model.preparingEntry?.id == entry.id
    }

    private var playSymbol: String {
        if model.preparingEntry?.id == entry.id { return "hourglass" }
        if isCurrent, model.player.isPlaying { return "pause.circle" }
        return "play.circle"
    }

    static func hoursAndMinutes(_ seconds: TimeInterval) -> String {
        SafeTime.hoursAndMinutes(seconds)
    }
}
