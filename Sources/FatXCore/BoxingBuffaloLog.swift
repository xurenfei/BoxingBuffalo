import Foundation

/// Append-only diagnostic log at `~/Library/Logs/BoxingBuffalo.log`.
///
/// The permission dance around `/dev/rdisk*` is invisible from the UI when it
/// fails — the only symptom is "still read-only". Every privilege request and
/// every device open therefore records what it ran and what came back, so the
/// failure can be read off disk instead of guessed at.
public enum BoxingBuffaloLog {

    public static var logURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/BoxingBuffalo.log")
    }

    public static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
