import SwiftUI
import AudibleKit

/// What the sidebar is filtering by.
enum LibraryFilter: Hashable {
    case all
    case downloaded
    case inProgress
    case finished
    case series(String)

    var title: String {
        switch self {
        case .all: return "All Titles"
        case .downloaded: return "Downloaded"
        case .inProgress: return "In Progress"
        case .finished: return "Finished"
        case .series(let name): return name
        }
    }

    func matches(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: return true
        case .downloaded: return entry.isDownloaded
        case .inProgress: return entry.isInProgress
        case .finished: return entry.isFinished
        case .series(let name): return entry.book.series?.name == name
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var showingQueue = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(text: banner) { model.banner = nil }
                }
                grid
                // The bar appears as soon as a title is chosen, not once its
                // audio is ready, so a click has an immediate effect.
                if model.player.entry != nil || model.preparingEntry != nil {
                    Divider()
                    PlayerBar()
                }
            }
        }
        .searchable(text: $search, prompt: "Title, author, narrator, or series")
        .toolbar { toolbar }
        .sheet(isPresented: $showingQueue) { DownloadQueueView() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                label(.all, "books.vertical")
                label(.inProgress, "book")
                label(.downloaded, "arrow.down.circle")
                label(.finished, "checkmark.circle")
            }
            if !seriesNames.isEmpty {
                Section("Series") {
                    ForEach(seriesNames, id: \.self) { name in
                        label(.series(name), "square.stack")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func label(_ filter: LibraryFilter, _ symbol: String) -> some View {
        Label(filter.title, systemImage: symbol).tag(filter)
    }

    private var seriesNames: [String] {
        Set(model.entries.compactMap { $0.book.series?.name }).sorted()
    }

    // MARK: Grid

    private var visibleEntries: [LibraryEntry] {
        let filtered = model.entries.filter(filter.matches)
        guard !search.isEmpty else { return sorted(filtered) }
        let needle = search.lowercased()
        return sorted(filtered.filter { entry in
            entry.book.title.lowercased().contains(needle)
                || entry.book.authorLine.lowercased().contains(needle)
                || entry.book.narratorLine.lowercased().contains(needle)
                || (entry.book.series?.name.lowercased().contains(needle) ?? false)
        })
    }

    /// Inside a series, order by the publisher's numbering. Elsewhere keep the
    /// store's order, which is newest purchase first.
    private func sorted(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        guard case .series = filter else { return entries }
        return entries.sorted {
            ($0.book.series?.sortIndex ?? .greatestFiniteMagnitude)
                < ($1.book.series?.sortIndex ?? .greatestFiniteMagnitude)
        }
    }

    private var grid: some View {
        ScrollView {
            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    model.entries.isEmpty ? "No titles yet" : "Nothing matches",
                    systemImage: "books.vertical",
                    description: Text(model.entries.isEmpty
                        ? "Refresh to fetch your Audible library."
                        : "Try a different search."))
                .padding(.top, 80)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)],
                    spacing: 24
                ) {
                    ForEach(visibleEntries) { entry in
                        BookTile(entry: entry, isSelected: selection.contains(entry.id))
                            .onTapGesture(count: 2) { Task { await model.play(entry) } }
                            .onTapGesture { toggle(entry.id) }
                            .contextMenu { menu(for: entry) }
                            .accessibilityLabel(
                                "\(entry.book.title) by \(entry.book.authorLine)")
                    }
                }
                .padding(20)
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    @ViewBuilder
    private func menu(for entry: LibraryEntry) -> some View {
        Button(entry.isDownloaded ? "Play" : "Stream") {
            Task { await model.play(entry) }
        }
        if entry.isDownloaded {
            Button("Remove Download") { Task { await model.removeDownload(entry) } }
        } else {
            Button("Download") { model.download([entry]) }
        }
        if !entry.bookmarks.isEmpty {
            Divider()
            Text("\(entry.bookmarks.count) bookmarks")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                model.download(selection.compactMap { id in
                    model.entries.first { $0.id == id }
                })
                selection.removeAll()
            } label: {
                Label("Download Selected", systemImage: "arrow.down.circle")
            }
            .disabled(selection.isEmpty)
        }
        ToolbarItem {
            Button { showingQueue = true } label: {
                Label("Downloads", systemImage: "tray.and.arrow.down")
            }
            .badge(model.queue.jobs.filter(\.state.isActive).count)
        }
        ToolbarItem {
            Button { Task { await model.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
        }
    }
}

/// A message shown in place, above the content it concerns.
struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary)
    }
}
