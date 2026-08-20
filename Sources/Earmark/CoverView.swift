import SwiftUI
import AppKit

/// A title's cover, or a coloured card carrying its name until the cover
/// arrives.
///
/// The card is never blank and never a spinner: a name on a colour is
/// readable, tells the reader which book this is, and stays still.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    /// Length of a side. Used to size the title on a placeholder.
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 6 : 4))
        .task(id: entry.id) {
            image = await model.covers.image(for: entry.id, url: entry.book.coverURL)
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: CoverView.colors(for: entry.id),
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            VStack(spacing: size > 100 ? 6 : 2) {
                Text(entry.book.title)
                    .font(.system(size: max(9, size * 0.11), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(size > 100 ? 4 : 2)
                    .minimumScaleFactor(0.6)

                if size > 100, !entry.book.authorLine.isEmpty {
                    Text(entry.book.authorLine)
                        .font(.system(size: max(8, size * 0.075)))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(size * 0.1)
        }
    }

    /// Two colours for a title, built from its own hue.
    static func colors(for identifier: String) -> [Color] {
        let hue = CoverPalette.hue(for: identifier)
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.62),
            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                  saturation: 0.68, brightness: 0.44)
        ]
    }
}

/// Picks a colour for a title from its identifier.
///
/// Kept apart from the view so it holds no drawing types: it is plain
/// arithmetic, and it is what the tests check.
enum CoverPalette {
    /// A hue from 0 to 1 for an identifier.
    ///
    /// The same identifier always gives the same hue, so a card does not
    /// change colour every time the library redraws.
    static func hue(for identifier: String) -> Double {
        let hash = identifier.unicodeScalars.reduce(UInt64(5381)) { total, scalar in
            total &* 33 &+ UInt64(scalar.value)
        }
        return Double(hash % 360) / 360
    }
}
