import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 480)
    }
}

/// Which versions to be offered, and what to do with them.
struct UpdateSettings: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        @Bindable var updates = updates

        Form {
            Section {
                LabeledContent("This copy", value: updates.current.description)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates", isOn: $updates.checksForUpdates)
                Text("Nothing is requested while this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Offer me", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                Text(updates.channel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Install without asking", isOn: $updates.installsWithoutAsking)
                    .disabled(!updates.checksForUpdates)
                Text("A download is put in place only when it is signed by the same "
                     + "developer as this copy. If it is not, it is deleted and nothing "
                     + "is replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Faulty builds") {
                Toggle("Warn me about faulty builds", isOn: $updates.warnsAboutFaultyBuilds)
                Text("Reads a short list from the Earmark site on launch and says so if "
                     + "this version is on it. Nothing is sent about what you have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button("Check Now") { Task { await updates.check() } }
                        .disabled(isBusy)
                    if isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                available
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private var isBusy: Bool {
        switch updates.state {
        case .looking, .installing: return true
        default: return false
        }
    }

    /// When it last looked, or why it could not.
    private var status: String {
        switch updates.state {
        case .failed(let reason): return reason
        case .installing(let step): return step
        case .upToDate: return "This is the newest on your channel."
        default:
            guard let date = updates.lastCheckedAt else { return "Not checked yet." }
            return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    @ViewBuilder
    private var available: some View {
        if case .available(let release) = updates.state {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(release.version) is available")
                    .font(.callout.weight(.medium))
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(release.notes)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                HStack {
                    Button("Install \(release.version)") {
                        Task { await updates.install(release) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Release Page") { updates.openReleasePage(release) }
                    Button("Skip This Version") { updates.skip(release) }
                    Spacer()
                }
            }
        } else if let release = updates.offerAfterFailure {
            // An install nobody asked for went wrong. This copy is now known
            // to be behind, so it is offered rather than left unsaid.
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing \(release.version) did not finish.")
                    .font(.callout.weight(.medium))
                HStack {
                    Button("Try Again") { Task { await updates.install(release) } }
                    Button("Open Release Page") { updates.openReleasePage(release) }
                }
            }
        }
    }
}

/// Shown when the running version is on the list of faulty builds.
struct AdvisoryBanner: View {
    @Environment(UpdateModel.self) private var updates
    let advisory: Advisory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: advisory.severity == .critical
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(advisory.severity == .critical ? .red : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(advisory.summary)
                    .font(.callout.weight(.semibold))
                Text(advisory.detail)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let fix = advisory.fixedIn {
                        Button("Install \(fix)") { Task { await updates.installFix() } }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    if let back = advisory.rollBackTo {
                        Button("Go Back to \(back)") { Task { await updates.rollBack() } }
                            .controlSize(.small)
                    }
                    // A critical build offers no way to be quiet about it.
                    if advisory.severity == .serious {
                        Button("Keep This Version") { updates.dismissAdvisory() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background((advisory.severity == .critical ? Color.red : Color.orange).opacity(0.12))
    }
}
