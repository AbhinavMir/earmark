import SwiftUI

/// One cover in the grid, with its download state and listening progress.
struct BookTile: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    let isSelected: Bool

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
