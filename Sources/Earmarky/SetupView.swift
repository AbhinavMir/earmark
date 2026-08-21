import SwiftUI

/// Shown while the library is fetched and its covers are cached.
///
/// The work happens once, and doing it behind a plain screen is better than
/// letting a half-built library appear and shift under the reader.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            AppIconView(size: 76)

            VStack(spacing: 8) {
                Text("Setting your library up")
                    .font(.title2.weight(.semibold))
                Text(model.setupMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let fraction = model.setupFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 260)
            }

            Text("This happens once. Covers are kept on this Mac, so the "
                 + "library opens without the network afterwards.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
