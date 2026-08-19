import SwiftUI

/// The download queue, with a reason on every failure and a way to retry it.
struct DownloadQueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear Finished") { model.queue.clearCompleted() }
                Button("Done") { dismiss() }
            }
            .padding(16)

            Divider()

            if model.queue.jobs.isEmpty {
                ContentUnavailableView(
                    "Nothing downloading",
                    systemImage: "tray",
                    description: Text("Select titles in the library and choose Download."))
                .frame(height: 240)
            } else {
                List(model.queue.jobs) { job in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title).lineLimit(1)
                            Text(job.state.label)
                                .font(.caption)
                                .foregroundStyle(isFailed(job.state) ? .red : .secondary)
                        }
                        Spacer()
                        if case .downloading(let fraction) = job.state, let fraction {
                            ProgressView(value: fraction).frame(width: 90)
                        } else if job.state.isActive {
                            ProgressView().controlSize(.small)
                        }
                        if isFailed(job.state) {
                            Button("Retry") { model.queue.retry(job.asin) }
                        }
                        if job.state == .queued {
                            Button("Cancel") { model.queue.cancel(job.asin) }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(height: 320)
            }
        }
        .frame(width: 520)
    }

    private func isFailed(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
