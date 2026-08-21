import SwiftUI
import AppKit

/// The application's own icon, drawn from the bundle.
///
/// A symbol standing in for it is one more thing to keep in step with the
/// real one.
struct AppIconView: View {
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "headphones").font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}
