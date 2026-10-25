import Foundation

/// Tiny append-only file logger: ~/Library/Logs/PiPGlass/PiPGlass.log
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PiPGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("PiPGlass.log")
        // Keep the log small: start fresh if it grew past 1 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: file)
        }
        return file
    }()

    private static let queue = DispatchQueue(label: "pipglass.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
