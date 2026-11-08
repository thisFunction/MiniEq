import Foundation
import os

/// Status messages go to the system log (Console.app, subsystem "com.skoczylas.MiniEQ").
/// Builds made with build.sh also append them to MiniEQ/logs/MiniEQ.log for easy troubleshooting.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.skoczylas.MiniEQ", category: "engine")
    private static let fileURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "MiniEQLogFile") as? String)
        .map { URL(fileURLWithPath: $0) }
    private static let fileQueue = DispatchQueue(label: "com.skoczylas.MiniEQ.log")
    private static let maxFileSize: UInt64 = 1_000_000

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard let fileURL else { return }
        let now = Date()
        fileQueue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            guard let data = "\(formatter.string(from: now))  \(message)\n".data(using: .utf8) else { return }
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
            if size == 0 || size > maxFileSize {
                try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL)
            } else if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}
