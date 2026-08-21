import SwiftUI

/// Says what is happening with versions, in the window rather than in
/// settings. Somebody who never opens settings still needs to be told.
struct UpdateBar: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        switch updates.state {
        case .available(let release):
            bar(tint: .blue, symbol: "arrow.down.circle.fill") {
                Text("Earmark \(release.version) is available")
                    .font(.callout.weight(.medium))
            } actions: {
                Button("Install") { Task { await updates.install(release) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Release Notes") { updates.openReleasePage(release) }
                    .controlSize(.small)
                Button("Later") { updates.skip(release) }
                    .controlSize(.small)
            }

        case .installing(let step):
            bar(tint: .blue, symbol: "arrow.down.circle") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout)
                }
            } actions: { EmptyView() }

        case .installed(let version):
            bar(tint: .green, symbol: "checkmark.circle.fill") {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Earmark \(version) is ready")
                        .font(.callout.weight(.medium))
                    Text("It takes effect when Earmark restarts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                Button("Restart Now") { updates.restartNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Later") { updates.restartLater() }
                    .controlSize(.small)
            }

        case .failed(let reason):
            if let release = updates.offerAfterFailure {
                bar(tint: .orange, symbol: "exclamationmark.triangle.fill") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Installing \(release.version) did not finish")
                            .font(.callout.weight(.medium))
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } actions: {
                    Button("Try Again") { Task { await updates.install(release) } }
                        .controlSize(.small)
                    Button("Release Page") { updates.openReleasePage(release) }
                        .controlSize(.small)
                }
            }

        default:
            EmptyView()
        }
    }

    private func bar<Content: View, Actions: View>(
        tint: Color,
        symbol: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint)
            content()
            Spacer(minLength: 12)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1))
    }
}
