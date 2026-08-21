import SwiftUI

/// The application's settings.
struct SettingsView: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        TabView {
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 460)
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

                Picker("Offer me", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.inline)

                Text(updates.channel.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Look for newer versions on launch", isOn: $updates.checksOnLaunch)
                Toggle("Install what it finds", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksOnLaunch)
                Text("A download is only put in place when it is signed by the same "
                     + "developer as this copy. If it is not, it is deleted and nothing "
                     + "is replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Check Now") {
                        Task { await updates.check() }
                    }
                    .disabled(isBusy)

                    statusText
                }
                if case .available(let release) = updates.state {
                    HStack {
                        Text("\(release.version) is available")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Install") { Task { await updates.install(release) } }
                            .buttonStyle(.borderedProminent)
                    }
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text(release.notes)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
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

    @ViewBuilder
    private var statusText: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .looking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("This is the newest on your channel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available:
            EmptyView()
        case .installing(let step):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(step).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }
}

/// Shown when the running version is on the recall list.
struct RecallBanner: View {
    @Environment(UpdateModel.self) private var updates
    let recall: Recall

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(recall.version) has a problem")
                    .font(.callout.weight(.semibold))
                Text(recall.reason)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let fix = recall.fixedIn {
                Button("Install \(fix)") { Task { await updates.installRecallFix() } }
                    .buttonStyle(.borderedProminent)
            }
            if let lastGood = recall.lastGood {
                Button("Go Back to \(lastGood)") { Task { await updates.installLastGood() } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
    }
}
