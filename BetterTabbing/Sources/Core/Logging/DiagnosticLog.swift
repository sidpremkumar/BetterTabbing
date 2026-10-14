import Foundation

/// Lightweight always-on diagnostic logger that appends to a file so intermittent
/// bugs can be inspected after the fact (Console/stdout is lost for the bundled app).
/// Log file: ~/Library/Logs/BetterTabbing/BetterTabbing.log (rotates once at ~5MB).
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BetterTabbing/BetterTabbing.log")
    }

    private let queue = DispatchQueue(label: "com.sparechange.BetterTabbing.diagnosticlog", qos: .utility)
    private let maxFileSize: UInt64 = 5 * 1024 * 1024
    private var handle: FileHandle?

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    /// Append a line to the log file (and mirror to stdout for terminal runs).
    func log(_ message: String) {
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)"
        print(line)
        queue.async { [weak self] in
            self?.write(line + "\n")
        }
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            if handle == nil {
                try openHandle()
            }
            rotateIfNeeded()
            try handle?.write(contentsOf: data)
        } catch {
            // Logging must never take the app down; drop the line.
            handle = nil
        }
    }

    private func openHandle() throws {
        let url = Self.logFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
    }

    private func rotateIfNeeded() {
        guard let h = handle, let offset = try? h.offset(), offset > maxFileSize else { return }
        try? h.close()
        handle = nil
        let url = Self.logFileURL
        let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        try? openHandle()
    }
}
