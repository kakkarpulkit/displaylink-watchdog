import Foundation
import os

// MARK: - Log entry model

struct LogEntry: Identifiable {
    let id   = UUID()
    let date = Date()
    let message: String

    var formattedTime: String { Self.timeFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - Log store

/// Wraps os.Logger with a 100-entry in-memory ring buffer for the in-app log viewer.
/// All public methods are safe to call from any thread.
final class LogStore: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []

    static let maxEntries = 100

    private let logger = Logger(
        subsystem: "com.kakkarpulkit.displaylink-watchdog",
        category: "watchdog"
    )

    func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let entry = LogEntry(message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            entries.append(entry)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
    }
}
