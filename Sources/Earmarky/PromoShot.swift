import SwiftUI
import AppKit
import AudibleKit

/// Draws a picture of the library without a screen.
///
/// The same views the application uses are drawn into an image, so what this
/// produces is what a person sees rather than a drawing of it. It runs when
/// the application is started with `--export-shot <path>`.
@MainActor
enum PromoShot {

    /// Reads the argument, if it is there.
    static var requestedPath: String? {
        value(after: "--export-shot")
    }

    /// Where to write a set of pictures, if that was asked for.
    static var requestedScenesPath: String? {
        value(after: "--export-scenes")
    }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.count > index + 1
        else { return nil }
        return arguments[index + 1]
    }

    /// Draws several pictures of the library, one per part of it.
    static func runScenes(directory: String) async {
        let store = LibraryStore()
        try? await store.load()
        let all = await store.sortedEntries
        let covers = CoverCache()

        var artwork: [String: NSImage] = [:]
        for entry in all.prefix(30) {
            artwork[entry.id] = await covers.image(for: entry.id, url: entry.book.coverURL)
        }

        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        let scenes: [(String, ShotView)] = [
            ("01-library", ShotView(
                entries: Array(all.prefix(12)), artwork: artwork)),
            ("02-progress", ShotView(
                entries: Array(all.filter { ($0.progress ?? 0) > 0.005 }.prefix(12)),
                artwork: artwork, sidebarSelection: "In Progress")),
            ("03-series", ShotView(
                entries: Array(all.filter { $0.book.series != nil }.prefix(12)),
                artwork: artwork, sidebarSelection: "Culture", grouped: true)),
            ("04-sound", ShotView(
                entries: Array(all.prefix(12)), artwork: artwork, showsSound: true))
        ]

        for (name, scene) in scenes {
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            print("Wrote \(name).png")
        }
        exit(0)
    }

    /// Draws the library and writes it, then leaves.
    static func run(path: String) async {
        let store = LibraryStore()
        try? await store.load()
        let entries = await store.sortedEntries
        // Covers are read before drawing. A drawing made without a screen
        // never runs the work a view would normally start when it appears.
        let covers = CoverCache()
        let shown = Array(entries.prefix(12))
        var artwork: [String: NSImage] = [:]
        for entry in shown {
            artwork[entry.id] = await covers.image(
                for: entry.id, url: entry.book.coverURL)
        }

        let view = ShotView(entries: shown, artwork: artwork)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("The picture could not be drawn.\n".utf8))
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

/// The library as a picture: a window of rows, with what is playing beneath.
struct ShotView: View {
    let entries: [LibraryEntry]
    let artwork: [String: NSImage]
    var sidebarSelection = "All Titles"
    var grouped = false
    var showsSound = false

    var body: some View {
        window
            .frame(width: 1_040)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.30), radius: 34, y: 16)
            .overlay(alignment: .bottomTrailing) {
                if showsSound { soundPanel.padding(.trailing, 26).padding(.bottom, 76) }
            }
            // The same air on every side. The picture takes its size from
            // what is in it rather than being cut to fit a shape.
            .padding(84)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.20, blue: 0.20),
                             Color(red: 0.02, green: 0.13, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var window: some View {
        VStack(spacing: 0) {
            titlebar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                rows
            }
            Divider()
            player
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titlebar: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.19)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 11, height: 11)
            Spacer()
            Text("Earmarky").font(.system(size: 12, weight: .semibold))
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "list.bullet")
                Image(systemName: "arrow.down.circle")
                Image(systemName: "arrow.clockwise")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            label("All Titles", "books.vertical", selected: sidebarSelection == "All Titles")
            label("In Progress", "book", selected: sidebarSelection == "In Progress")
            label("Downloaded", "arrow.down.circle", selected: sidebarSelection == "Downloaded")
            label("Finished", "checkmark.circle", selected: sidebarSelection == "Finished")
            Text("SERIES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
                .padding(.leading, 8)
            ForEach(seriesNames.prefix(6), id: \.self) { name in
                label(name, "square.stack", selected: sidebarSelection == name)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 186, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var seriesNames: [String] {
        Array(Set(entries.compactMap { $0.book.series?.name })).sorted()
    }

    private func label(_ text: String, _ symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.16) : .clear))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 1) {
            if grouped, let series = entries.first?.book.series?.name {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(series).font(.system(size: 12, weight: .semibold))
                    Text("\(entries.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            }
            ForEach(entries) { entry in
                ShotRow(entry: entry, image: artwork[entry.id])
                    .padding(.leading, grouped ? 16 : 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The sound controls, as they appear over the library.
    private var soundPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Sound").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Reset").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            slider("Speed", "1.50×", 0.4)
            Divider()
            slider("Pitch", "+0 cents", 0.5)
            slider("Bass", "+2.0 dB", 0.58)
            slider("Voice", "+3.0 dB", 0.62)
            slider("Treble", "+1.0 dB", 0.54)
            Divider()
            HStack(spacing: 5) {
                ForEach(["Flat", "Voice", "Warm", "Bright"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 10))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                }
            }
        }
        .padding(14)
        .frame(width: 268)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private func slider(_ name: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 11))
                Spacer()
                Text(value).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 3)
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * fraction, height: 3)
                    Circle().fill(.white)
                        .frame(width: 11, height: 11)
                        .shadow(radius: 1)
                        .offset(x: proxy.size.width * fraction - 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
        }
    }

    private var player: some View {
        let playing = entries.first { $0.progress ?? 0 > 0.02 } ?? entries.first
        return HStack(spacing: 12) {
            if let playing {
                ShotCover(entry: playing, image: artwork[playing.id], size: 42)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(playing?.book.title ?? "")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(playing?.chapters.first?.title ?? playing?.book.authorLine ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 210, alignment: .leading)

            Spacer()
            HStack(spacing: 16) {
                Image(systemName: "backward.end.fill")
                Image(systemName: "gobackward.15")
                Image(systemName: "pause.fill").font(.system(size: 16))
                Image(systemName: "goforward.30")
                Image(systemName: "forward.end.fill")
            }
            .font(.system(size: 12))
            Spacer()

            HStack(spacing: 6) {
                Capsule().fill(.quaternary).frame(width: 70, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor).frame(width: 40, height: 4)
                    }
                Text("1.50×").font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "slider.horizontal.3").font(.system(size: 12))
            Image(systemName: "moon").font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One row, drawn as the list draws it.
struct ShotRow: View {
    let entry: LibraryEntry
    let image: NSImage?

    var body: some View {
        HStack(spacing: 11) {
            ShotCover(entry: entry, image: image, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.book.title)
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(entry.book.authorLine.isEmpty
                         ? "Unknown author" : entry.book.authorLine)
                    if let series = entry.book.series {
                        Text("·")
                        Text(series.position.map { "\(series.name) \($0)" } ?? series.name)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 10)

            if let progress = entry.progress, progress > 0.005 {
                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: 52, height: 4)
                        Capsule().fill(Color.accentColor)
                            .frame(width: 52 * progress, height: 4)
                    }
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(entry.percentText ?? "")
                            .font(.system(size: 10).monospacedDigit())
                        if let left = entry.remainingText {
                            Text("\(left) left")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 118, alignment: .trailing)
            } else {
                Text(entry.book.duration.map(SafeTime.hoursAndMinutes) ?? "")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .trailing)
            }

            HStack(spacing: 9) {
                Image(systemName: "play.circle")
                Image(systemName: entry.isDownloaded
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(entry.isDownloaded ? .green : .secondary)
            }
            .font(.system(size: 13))
            .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }
}

/// A cover read from the cache on disk, so the picture shows real artwork.
struct ShotCover: View {
    let entry: LibraryEntry
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: CoverView.colors(for: entry.id),
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
