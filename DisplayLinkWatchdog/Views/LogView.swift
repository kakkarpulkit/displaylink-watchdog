import SwiftUI

/// Scrollable window showing the in-memory log ring buffer.
struct LogView: View {

    @EnvironmentObject var logStore: LogStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 320, idealHeight: 420)
    }

    // MARK: - Sub-views

    private var toolbar: some View {
        HStack {
            Text("Watchdog Log")
                .font(.headline)
            Spacer()
            Button("Clear") { logStore.clear() }
                .buttonStyle(.borderless)
                .disabled(logStore.entries.isEmpty)
            Button("Done")  { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var logContent: some View {
        Group {
            if logStore.entries.isEmpty {
                emptyState
            } else {
                entriesList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("No log entries yet")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entriesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(entry.formattedTime)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .leading)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal)
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: logStore.entries.count) { _ in
                if let last = logStore.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = logStore.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
